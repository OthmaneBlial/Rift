#define _GNU_SOURCE

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <limits.h>
#include <pwd.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int fail(const char *operation);

static volatile sig_atomic_t child_pid = -1;
static volatile sig_atomic_t exec_pid = -1;
static volatile sig_atomic_t pending_signal = 0;

static void forward_stop_signal(int signal_number) {
    int saved_errno = errno;
    pending_signal = signal_number;
    if (child_pid > 0) kill((pid_t)child_pid, signal_number);
    if (exec_pid > 0) kill((pid_t)exec_pid, signal_number);
    errno = saved_errno;
}

static int install_stop_signal_handler(void) {
    struct sigaction action = {.sa_handler = forward_stop_signal};
    sigemptyset(&action.sa_mask);
    return sigaction(SIGTERM, &action, NULL);
}

static void restore_default_stop_signal(void) {
    struct sigaction action = {.sa_handler = SIG_DFL};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
}

static int decode_status(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}

static int child_status(pid_t child) {
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return fail("wait for container process");
    }
    child_pid = -1;
    return decode_status(status);
}

static int fail(const char *operation) {
    fprintf(stderr, "rift-exec: %s: %s\n", operation, strerror(errno));
    return 125;
}

static int numeric_id(const char *text, unsigned int *result) {
    if (!*text) return 0;
    unsigned int value = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
        const unsigned int digit = *p - '0';
        if (value > (UINT_MAX - digit) / 10) return -1;
        value = value * 10 + digit;
    }
    if (value == UINT_MAX) return -1;
    *result = (unsigned int)value;
    return 1;
}

static int resolve_user(const char *spec, uid_t *uid, gid_t *gid, char username[256]) {
    *uid = 0;
    *gid = 0;
    username[0] = 0;
    if (!*spec) {
        struct passwd *entry = getpwuid(*uid);
        if (!entry) return 0;
        *gid = entry->pw_gid;
        if (strlen(entry->pw_name) >= 256) return -1;
        strcpy(username, entry->pw_name);
        return 0;
    }
    if (strlen(spec) > 255) return -1;
    char value[256];
    strcpy(value, spec);
    char *group = strchr(value, ':');
    if (group) {
        *group++ = 0;
        if (!*group || strchr(group, ':')) return -1;
    }
    struct passwd *entry = NULL;
    if (*value && strcmp(value, "root") != 0) {
        unsigned int number;
        int numeric = numeric_id(value, &number);
        if (numeric < 0) return -1;
        if (numeric) {
            *uid = (uid_t)number;
            entry = getpwuid(*uid);
            if (entry) *gid = entry->pw_gid;
        } else {
            entry = getpwnam(value);
            if (!entry) return -1;
            *uid = entry->pw_uid;
            *gid = entry->pw_gid;
        }
    } else {
        entry = getpwuid(*uid);
        if (entry) *gid = entry->pw_gid;
    }
    if (entry) {
        if (strlen(entry->pw_name) >= 256) return -1;
        strcpy(username, entry->pw_name);
    }
    if (group) {
        unsigned int number;
        int numeric = numeric_id(group, &number);
        if (numeric < 0) return -1;
        if (numeric) {
            *gid = (gid_t)number;
        } else {
            struct group *entry = getgrnam(group);
            if (!entry) return -1;
            *gid = entry->gr_gid;
        }
    }
    return 0;
}

static int open_volume_directory(const char *target) {
    size_t target_length = strlen(target);
    if (target[0] != '/' || target_length > 4096) {
        errno = EINVAL;
        fail("invalid volume target");
        return -1;
    }
    int directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) {
        fail("open volume root");
        return -1;
    }
    const char *part = target + 1;
    while (*part) {
        const char *slash = strchr(part, '/');
        size_t length = slash ? (size_t)(slash - part) : strlen(part);
        if (!length || length > NAME_MAX || (length == 1 && part[0] == '.') ||
            (length == 2 && part[0] == '.' && part[1] == '.')) {
            close(directory);
            errno = EINVAL;
            fail("invalid volume target");
            return -1;
        }
        char component[NAME_MAX + 1];
        memcpy(component, part, length);
        component[length] = 0;
        int next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(directory, component, 0755) != 0 && errno != EEXIST) {
                close(directory);
                fail("create volume target");
                return -1;
            }
            next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            close(directory);
            fail("open volume target");
            return -1;
        }
        close(directory);
        directory = next;
        if (!slash) break;
        part = slash + 1;
    }
    return directory;
}

static int mount_directory_volume(const char *tag, const char *target, const char *mode) {
    if (target[strlen(target) - 1] == '/') {
        fputs("rift-exec: invalid volume target\n", stderr);
        return 125;
    }
    int directory = open_volume_directory(target);
    if (directory < 0) return 125;
    close(directory);
    if (mount(tag, target, "virtiofs", MS_NOSUID | MS_NODEV | (strcmp(mode, "ro") == 0 ? MS_RDONLY : 0), NULL) != 0)
        return fail("mount volume");
    return 0;
}

static int prepare_file_target(const char *target) {
    size_t target_length = strlen(target);
    if (target[0] != '/' || target_length < 2 || target_length > 4096 || target[target_length - 1] == '/') {
        fputs("rift-exec: invalid file volume target\n", stderr);
        return 125;
    }
    const char *separator = strrchr(target, '/');
    const char *name = separator + 1;
    size_t name_length = strlen(name);
    if (!name_length || name_length > NAME_MAX) {
        fputs("rift-exec: invalid file volume target\n", stderr);
        return 125;
    }
    char parent[PATH_MAX];
    size_t parent_length = separator == target ? 1 : (size_t)(separator - target);
    if (parent_length >= sizeof(parent)) {
        errno = ENAMETOOLONG;
        return fail("file volume target");
    }
    memcpy(parent, target, parent_length);
    parent[parent_length] = 0;
    if (separator == target) strcpy(parent, "/");
    int directory = open_volume_directory(parent);
    if (directory < 0) return 125;
    struct stat info;
    if (fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT) {
            close(directory);
            return fail("inspect file volume target");
        }
        int file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (file < 0) {
            close(directory);
            return fail("create file volume target");
        }
        close(file);
    } else if (!S_ISREG(info.st_mode)) {
        close(directory);
        errno = EINVAL;
        return fail("file volume target must be a regular file");
    }
    close(directory);
    return 0;
}

static int mount_file_volume(const char *tag, const char *target, const char *mode) {
    if (prepare_file_target(target) != 0) return 125;
    char share_path[] = "/.rift-volume-XXXXXX";
    if (!mkdtemp(share_path)) return fail("create file volume mountpoint");
    char source[PATH_MAX];
    if (snprintf(source, sizeof(source), "%s/source", share_path) >= (int)sizeof(source)) {
        rmdir(share_path);
        errno = ENAMETOOLONG;
        return fail("file volume source");
    }
    const int read_only = strcmp(mode, "ro") == 0;
    const unsigned long flags = MS_NOSUID | MS_NODEV | (read_only ? MS_RDONLY : 0);
    if (mount(tag, share_path, "virtiofs", flags, NULL) != 0) {
        int status = fail("mount file volume share");
        rmdir(share_path);
        return status;
    }
    int bound = 0;
    int status = 0;
    if (mount(source, target, NULL, MS_BIND, NULL) != 0) {
        status = fail("bind file volume");
    } else {
        bound = 1;
        if (mount(NULL, target, NULL, MS_BIND | MS_REMOUNT | MS_NOSUID | MS_NODEV | (read_only ? MS_RDONLY : 0), NULL) != 0)
            status = fail("set file volume mode");
    }
    if (umount2(share_path, 0) != 0 && status == 0) status = fail("unmount file volume share");
    if (rmdir(share_path) != 0 && status == 0) status = fail("remove file volume mountpoint");
    if (status != 0 && bound) umount2(target, 0);
    return status;
}

static int mount_volume(const char *tag, const char *target, const char *mode, const char *kind) {
    size_t target_length = strlen(target);
    if ((strcmp(mode, "ro") != 0 && strcmp(mode, "rw") != 0) ||
        (strcmp(kind, "directory") != 0 && strcmp(kind, "file") != 0) || target[0] != '/' ||
        target_length < 2 || target_length > 4096 || target[target_length - 1] == '/') {
        fputs("rift-exec: invalid volume mode or type\n", stderr);
        return 125;
    }
    if (strcmp(kind, "file") == 0) return mount_file_volume(tag, target, mode);
    return mount_directory_volume(tag, target, mode);
}

static int mountpoint(const char *path) {
    if (mkdir(path, 0755) != 0 && errno != EEXIST) return fail("create mountpoint");
    int directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return fail("open mountpoint");
    close(directory);
    return 0;
}

static int device(const char *path, unsigned int major_number, unsigned int minor_number) {
    if (mknod(path, S_IFCHR | 0600, makedev(major_number, minor_number)) != 0 || chmod(path, 0666) != 0)
        return fail("create device");
    return 0;
}

static int mount_standard_filesystems(void) {
    if (mountpoint("/dev") != 0) return 125;
    if (mount("tmpfs", "/dev", "tmpfs", MS_NOSUID | MS_NOEXEC, "mode=755,size=4m") != 0) return fail("mount /dev");
    if (device("/dev/null", 1, 3) != 0 || device("/dev/zero", 1, 5) != 0 ||
        device("/dev/random", 1, 8) != 0 || device("/dev/urandom", 1, 9) != 0 ||
        device("/dev/tty", 5, 0) != 0) return 125;
    if (mountpoint("/proc") != 0) return 125;
    if (mount("proc", "/proc", "proc", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) return fail("mount /proc");
    return 0;
}

static int allowed_capability(int capability) {
    switch (capability) {
        case CAP_CHOWN:
        case CAP_DAC_OVERRIDE:
        case CAP_FOWNER:
        case CAP_FSETID:
        case CAP_KILL:
        case CAP_SETGID:
        case CAP_SETUID:
        case CAP_NET_BIND_SERVICE:
            return 1;
        default:
            return 0;
    }
}

static int restrict_capabilities(void) {
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3, .pid = 0};
    struct __user_cap_data_struct data[2] = {{0}, {0}};
    for (int capability = 0; capability < 64; ++capability) {
        if (allowed_capability(capability)) {
            data[capability / 32].effective |= 1U << (capability % 32);
            data[capability / 32].permitted |= 1U << (capability % 32);
        } else if (prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) != 0 && errno != EINVAL) {
            return fail("drop capability bound");
        }
    }
    errno = 0;
    if (prctl(PR_CAPBSET_READ, 64, 0, 0, 0) != -1 || errno != EINVAL) {
        fputs("rift-exec: unsupported capability range\n", stderr);
        return 125;
    }
    if (syscall(SYS_capset, &header, data) != 0) return fail("restrict capabilities");
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return fail("disable privilege escalation");
    return 0;
}

#define EXEC_REQUEST_MAX (64U * 1024U)
#define EXEC_ARGUMENTS_MAX 256
#define EXEC_REQUEST_HEADER "RIFTEXEC1\n"

static int write_all(int descriptor, const void *contents, size_t length) {
    const char *cursor = contents;
    while (length) {
        ssize_t written = write(descriptor, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        cursor += written;
        length -= (size_t)written;
    }
    return 0;
}

static int exec_filename(char *result, size_t capacity, const char *id, const char *suffix) {
    int length = snprintf(result, capacity, "exec-%s.%s", id, suffix);
    if (length < 0 || (size_t)length >= capacity) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static int valid_exec_request_name(const char *name, char id[33]) {
    if (strlen(name) != 45 || strncmp(name, "exec-", 5) != 0 || strcmp(name + 37, ".request") != 0) return 0;
    for (size_t index = 5; index < 37; ++index) {
        if (!((name[index] >= '0' && name[index] <= '9') || (name[index] >= 'a' && name[index] <= 'f'))) return 0;
    }
    memcpy(id, name + 5, 32);
    id[32] = 0;
    return 1;
}

static int write_exec_result(int directory, const char *id, int status) {
    char result_name[64];
    char temporary_name[72];
    if (exec_filename(result_name, sizeof(result_name), id, "exit") != 0) return -1;
    int length = snprintf(temporary_name, sizeof(temporary_name), "%s.tmp", result_name);
    if (length < 0 || (size_t)length >= sizeof(temporary_name)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    unlinkat(directory, temporary_name, 0);
    int descriptor = openat(directory, temporary_name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) return -1;
    char contents[16];
    length = snprintf(contents, sizeof(contents), "%d\n", status);
    int failed = length < 0 || (size_t)length >= sizeof(contents) || write_all(descriptor, contents, (size_t)length) != 0;
    if (close(descriptor) != 0) failed = 1;
    if (failed || renameat(directory, temporary_name, directory, result_name) != 0) {
        unlinkat(directory, temporary_name, 0);
        return -1;
    }
    return 0;
}

static int publish_exec_error(int directory, const char *id, const char *message) {
    char output_name[64];
    if (exec_filename(output_name, sizeof(output_name), id, "output") != 0) return -1;
    int descriptor = openat(directory, output_name, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor >= 0) {
        write_all(descriptor, message, strlen(message));
        close(descriptor);
    }
    return write_exec_result(directory, id, 125);
}

static int parse_exec_arguments(char *contents, size_t length, char **command, size_t *count) {
    const size_t header_length = sizeof(EXEC_REQUEST_HEADER) - 1;
    if (length <= header_length || memcmp(contents, EXEC_REQUEST_HEADER, header_length) != 0 || contents[length - 1] != 0) return 0;
    size_t offset = header_length;
    *count = 0;
    while (offset < length) {
        if (*count == EXEC_ARGUMENTS_MAX) return 0;
        char *argument = contents + offset;
        char *end = memchr(argument, 0, length - offset);
        if (!end || (*count == 0 && end == argument)) return 0;
        command[(*count)++] = argument;
        offset = (size_t)(end - contents) + 1;
    }
    if (*count == 0) return 0;
    command[*count] = NULL;
    return 1;
}

static int run_exec(char *root, char *working_directory, char *user, char **command, int output) {
    if (dup2(output, STDOUT_FILENO) < 0 || dup2(output, STDERR_FILENO) < 0) return fail("attach exec output");
    int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (input < 0 || dup2(input, STDIN_FILENO) < 0) return fail("attach exec input");
    if (chroot(root) != 0) return fail("chroot exec process");
    if (chdir("/") != 0) return fail("chdir exec root");

    uid_t uid;
    gid_t gid;
    char username[256];
    if (resolve_user(user, &uid, &gid, username) != 0) {
        fputs("rift-exec: image user or group was not found\n", stderr);
        return 125;
    }
    if (restrict_capabilities() != 0) return 125;
    if (username[0]) {
        if (initgroups(username, gid) != 0) return fail("set supplementary groups");
    } else if (setgroups(0, NULL) != 0) {
        return fail("clear supplementary groups");
    }
    if (setgid(gid) != 0) return fail("setgid");
    if (setuid(uid) != 0) return fail("setuid");
    if (chdir(working_directory) != 0) return fail("chdir working directory");
    if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) return fail("close inherited descriptors");
    execvp(command[0], command);
    return fail("exec");
}

static int service_exec_request(int directory, char *root, char *working_directory, char *user) {
    int scan_descriptor = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (scan_descriptor < 0) return fail("scan exec requests");
    DIR *entries = fdopendir(scan_descriptor);
    if (!entries) {
        close(scan_descriptor);
        return fail("scan exec requests");
    }
    char request_name[64] = {0};
    char id[33];
    struct dirent *entry;
    while ((entry = readdir(entries)) != NULL) {
        if (!valid_exec_request_name(entry->d_name, id)) continue;
        strcpy(request_name, entry->d_name);
        break;
    }
    closedir(entries);
    if (!request_name[0]) return 0;

    int request = openat(directory, request_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (request < 0) return errno == ENOENT ? 0 : fail("open exec request");
    struct stat info;
    int valid = fstat(request, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size <= EXEC_REQUEST_MAX;
    char contents[EXEC_REQUEST_MAX];
    size_t length = 0;
    if (valid) {
        for (;;) {
            ssize_t count = read(request, contents + length, sizeof(contents) - length);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) {
                valid = 0;
                break;
            }
            if (count == 0) break;
            length += (size_t)count;
            if (length == sizeof(contents)) {
                char extra;
                ssize_t more = read(request, &extra, 1);
                if (more != 0) valid = 0;
                break;
            }
        }
    }
    close(request);
    unlinkat(directory, request_name, 0);

    char *command[EXEC_ARGUMENTS_MAX + 1];
    size_t argument_count = 0;
    if (!valid || !parse_exec_arguments(contents, length, command, &argument_count)) {
        publish_exec_error(directory, id, "rift-exec: invalid exec request\n");
        return 1;
    }

    char output_name[64];
    if (exec_filename(output_name, sizeof(output_name), id, "output") != 0) {
        publish_exec_error(directory, id, "rift-exec: invalid exec output path\n");
        return 1;
    }
    int output = openat(directory, output_name, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (output < 0) {
        write_exec_result(directory, id, 125);
        return 1;
    }
    pid_t process = fork();
    if (process < 0) {
        char message[256];
        int count = snprintf(message, sizeof(message), "rift-exec: fork exec process: %s\n", strerror(errno));
        if (count > 0) write_all(output, message, (size_t)count);
        close(output);
        write_exec_result(directory, id, 125);
        return 1;
    }
    if (process == 0) {
        child_pid = -1;
        exec_pid = -1;
        pending_signal = 0;
        restore_default_stop_signal();
        _exit(run_exec(root, working_directory, user, command, output));
    }

    close(output);
    exec_pid = process;
    if (pending_signal) kill(process, pending_signal);
    int status;
    while (waitpid(process, &status, 0) < 0) {
        if (errno != EINTR) {
            exec_pid = -1;
            write_exec_result(directory, id, 125);
            return fail("wait for exec process");
        }
    }
    exec_pid = -1;
    if (write_exec_result(directory, id, decode_status(status)) != 0) return fail("write exec status");
    return 1;
}

static int mark_exec_agent_ready(int directory) {
    int descriptor = openat(directory, "agent-ready", O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) return -1;
    return close(descriptor);
}

static uint32_t load_u32_le(const unsigned char value[4]) {
    return (uint32_t)value[0] | (uint32_t)value[1] << 8 | (uint32_t)value[2] << 16 | (uint32_t)value[3] << 24;
}

static int read_exact(int descriptor, void *buffer, size_t size) {
    unsigned char *cursor = buffer;
    while (size) {
        ssize_t count = read(descriptor, cursor, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            errno = count == 0 ? EINVAL : errno;
            return -1;
        }
        cursor += count;
        size -= (size_t)count;
    }
    return 0;
}

static int valid_owner_path(const char *path, size_t length) {
    if (!length || length > PATH_MAX || path[0] == '/' || path[length - 1] == '/') return 0;
    size_t start = 0;
    for (size_t index = 0; index <= length; ++index) {
        if (index < length && path[index] != '/') {
            if (path[index] == '\0') return 0;
            continue;
        }
        size_t component_length = index - start;
        if (!component_length || component_length > NAME_MAX ||
            (component_length == 1 && path[start] == '.') ||
            (component_length == 2 && path[start] == '.' && path[start + 1] == '.')) return 0;
        start = index + 1;
    }
    return 1;
}

static int chown_image_path(const char *root_path, char *path, uid_t uid, gid_t gid) {
    int directory = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return fail("open image root for ownership");
    char *part = path;
    for (;;) {
        char *separator = strchr(part, '/');
        if (!separator) break;
        *separator = '\0';
        int next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            int status = fail("open image owner parent");
            close(directory);
            *separator = '/';
            return status;
        }
        close(directory);
        directory = next;
        part = separator + 1;
    }
    int result = fchownat(directory, part, uid, gid, AT_SYMLINK_NOFOLLOW);
    int status = result == 0 ? 0 : fail("apply image ownership");
    close(directory);
    return status;
}

static int chown_image_root(const char *root_path, uid_t uid, gid_t gid) {
    int directory = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return fail("open image root for ownership");
    int result = fchownat(directory, ".", uid, gid, AT_SYMLINK_NOFOLLOW);
    int status = result == 0 ? 0 : fail("apply image root ownership");
    close(directory);
    return status;
}

static int apply_image_ownership(const char *root_path) {
    const int descriptor = open("/mnt/control/owners", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return errno == ENOENT ? 0 : fail("open image ownership manifest");
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 8 || info.st_size > 64 * 1024 * 1024) {
        close(descriptor);
        errno = EINVAL;
        return fail("validate image ownership manifest");
    }
    unsigned char magic[8];
    if (read_exact(descriptor, magic, sizeof(magic)) != 0 || memcmp(magic, "RIFTOWN1", sizeof(magic)) != 0) {
        close(descriptor);
        errno = EINVAL;
        return fail("read image ownership manifest");
    }
    off_t remaining = info.st_size - (off_t)sizeof(magic);
    unsigned long records = 0;
    while (remaining) {
        unsigned char header[12];
        if (remaining < (off_t)sizeof(header) || read_exact(descriptor, header, sizeof(header)) != 0) {
            close(descriptor);
            errno = EINVAL;
            return fail("read image ownership record");
        }
        remaining -= (off_t)sizeof(header);
        const uint32_t uid = load_u32_le(&header[0]);
        const uint32_t gid = load_u32_le(&header[4]);
        const uint32_t path_length = load_u32_le(&header[8]);
        if (++records > 1000000 || uid == UINT32_MAX || gid == UINT32_MAX || path_length > PATH_MAX ||
            (off_t)path_length > remaining || (uid == 0 && gid == 0)) {
            close(descriptor);
            errno = EINVAL;
            return fail("validate image ownership record");
        }
        if (path_length == 0) {
            if (chown_image_root(root_path, (uid_t)uid, (gid_t)gid) != 0) {
                close(descriptor);
                return 125;
            }
            continue;
        }
        char path[PATH_MAX + 1];
        if (read_exact(descriptor, path, path_length) != 0) {
            close(descriptor);
            errno = EINVAL;
            return fail("read image ownership path");
        }
        remaining -= (off_t)path_length;
        path[path_length] = '\0';
        if (!valid_owner_path(path, path_length)) {
            close(descriptor);
            errno = EINVAL;
            return fail("validate image ownership path");
        }
        if (chown_image_path(root_path, path, (uid_t)uid, (gid_t)gid) != 0) {
            close(descriptor);
            return 125;
        }
    }
    close(descriptor);
    return 0;
}

static int run_container(char **argv, unsigned long volume_count, int ready_descriptor) {
    if (apply_image_ownership(argv[1]) != 0) return 125;
    if (chroot(argv[1]) != 0) return fail("chroot");
    if (chdir("/") != 0) return fail("chdir root");

    uid_t uid;
    gid_t gid;
    char username[256];
    if (resolve_user(argv[3], &uid, &gid, username) != 0) {
        fputs("rift-exec: image user or group was not found\n", stderr);
        return 125;
    }
    for (unsigned long index = 0; index < volume_count; ++index) {
        int status = mount_volume(argv[5 + index * 4], argv[6 + index * 4], argv[7 + index * 4], argv[8 + index * 4]);
        if (status != 0) return status;
    }
    if (mount_standard_filesystems() != 0) return 125;
    if (restrict_capabilities() != 0) return 125;
    if (username[0]) {
        if (initgroups(username, gid) != 0) return fail("set supplementary groups");
    } else if (setgroups(0, NULL) != 0) {
        return fail("clear supplementary groups");
    }
    if (setgid(gid) != 0) return fail("setgid");
    if (setuid(uid) != 0) return fail("setuid");
    if (chdir(argv[2]) != 0) return fail("chdir working directory");
    if (pending_signal) return 128 + pending_signal;
    pid_t workload = fork();
    if (workload < 0) return fail("fork container workload");
    if (workload == 0) {
        child_pid = -1;
        close(ready_descriptor);
        pending_signal = 0;
        restore_default_stop_signal();
        if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) _exit(fail("close inherited descriptors"));
        execvp(argv[5 + volume_count * 4], argv + 5 + volume_count * 4);
        _exit(fail("exec"));
    }
    child_pid = workload;
    if (write(ready_descriptor, "R", 1) != 1) {
        close(ready_descriptor);
        kill(workload, SIGTERM);
        return fail("notify exec agent");
    }
    close(ready_descriptor);
    if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) return fail("close inherited descriptors");
    if (pending_signal) kill(workload, pending_signal);
    return child_status(workload);
}

int main(int argc, char **argv) {
    if (argc < 6) {
        fputs("rift-exec: missing command\n", stderr);
        return 125;
    }
    char *end;
    errno = 0;
    unsigned long volume_count = strtoul(argv[4], &end, 10);
    if (errno || *end || volume_count > 16 || argc < 6 + (int)volume_count * 4 || !argv[5 + volume_count * 4][0]) {
        fputs("rift-exec: invalid volume count or missing command\n", stderr);
        return 125;
    }
    if (install_stop_signal_handler() != 0) return fail("install stop signal handler");
    int control = open("/mnt/control/exec", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (control < 0) return fail("open exec control directory");
    int ready[2];
    if (pipe2(ready, O_CLOEXEC) != 0) {
        close(control);
        return fail("create exec agent channel");
    }
    if (unshare(CLONE_NEWNS | CLONE_NEWPID) != 0) return fail("create container namespaces");
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return fail("make mounts private");
    pid_t child = fork();
    if (child < 0) return fail("fork container process");
    if (child == 0) {
        close(ready[0]);
        close(control);
        child_pid = -1;
        return run_container(argv, volume_count, ready[1]);
    }
    close(ready[1]);
    child_pid = child;
    if (pending_signal) kill(child, pending_signal);
    char ready_signal;
    ssize_t received;
    do {
        received = read(ready[0], &ready_signal, 1);
    } while (received < 0 && errno == EINTR);
    close(ready[0]);
    if (received != 1 || ready_signal != 'R') {
        close(control);
        return child_status(child);
    }
    if (mark_exec_agent_ready(control) != 0) {
        close(control);
        kill(child, SIGTERM);
        return fail("publish exec agent readiness");
    }
    for (;;) {
        int status;
        pid_t finished = waitpid(child, &status, WNOHANG);
        if (finished == child) {
            child_pid = -1;
            close(control);
            return decode_status(status);
        }
        if (finished < 0 && errno != EINTR) {
            close(control);
            return fail("wait for container process");
        }
        if (!pending_signal && service_exec_request(control, argv[1], argv[2], argv[3]) == 125) {
            close(control);
            kill(child, SIGTERM);
            return 125;
        }
        usleep(50000);
    }
}
