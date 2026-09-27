#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <limits.h>
#include <pwd.h>
#include <sched.h>
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

static int resolve_user(const char *spec, uid_t *uid, gid_t *gid) {
    *uid = 0;
    *gid = 0;
    if (!*spec) return 0;
    if (strlen(spec) > 255) return -1;
    char value[256];
    strcpy(value, spec);
    char *group = strchr(value, ':');
    if (group) {
        *group++ = 0;
        if (!*group || strchr(group, ':')) return -1;
    }
    if (*value && strcmp(value, "root") != 0) {
        unsigned int number;
        int numeric = numeric_id(value, &number);
        if (numeric < 0) return -1;
        if (numeric) {
            *uid = (uid_t)number;
        } else {
            struct passwd *entry = getpwnam(value);
            if (!entry) return -1;
            *uid = entry->pw_uid;
            *gid = entry->pw_gid;
        }
    }
    if (group && strcmp(group, "root") != 0) {
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

static int mount_volume(const char *tag, const char *target, const char *mode) {
    size_t target_length = strlen(target);
    if (target[0] != '/' || target_length < 2 || target_length > 4096 || target[target_length - 1] == '/' ||
        (strcmp(mode, "ro") != 0 && strcmp(mode, "rw") != 0)) {
        fputs("rift-exec: invalid volume target or mode\n", stderr);
        return 125;
    }
    int directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) return fail("open volume root");
    const char *part = target + 1;
    while (*part) {
        const char *slash = strchr(part, '/');
        size_t length = slash ? (size_t)(slash - part) : strlen(part);
        if (!length || length > NAME_MAX || (length == 1 && part[0] == '.') ||
            (length == 2 && part[0] == '.' && part[1] == '.')) {
            close(directory);
            fputs("rift-exec: invalid volume target\n", stderr);
            return 125;
        }
        char component[NAME_MAX + 1];
        memcpy(component, part, length);
        component[length] = 0;
        int next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(directory, component, 0755) != 0 && errno != EEXIST) {
                close(directory);
                return fail("create volume target");
            }
            next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            close(directory);
            return fail("open volume target");
        }
        close(directory);
        directory = next;
        if (!slash) break;
        part = slash + 1;
    }
    close(directory);
    if (mount(tag, target, "virtiofs", MS_NOSUID | MS_NODEV | (strcmp(mode, "ro") == 0 ? MS_RDONLY : 0), NULL) != 0)
        return fail("mount volume");
    return 0;
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

static int run_container(char **argv, unsigned long volume_count) {
    if (chroot(argv[1]) != 0) return fail("chroot");
    if (chdir("/") != 0) return fail("chdir root");

    uid_t uid;
    gid_t gid;
    if (resolve_user(argv[3], &uid, &gid) != 0) {
        fputs("rift-exec: image user or group was not found\n", stderr);
        return 125;
    }
    for (unsigned long index = 0; index < volume_count; ++index) {
        int status = mount_volume(argv[5 + index * 3], argv[6 + index * 3], argv[7 + index * 3]);
        if (status != 0) return status;
    }
    if (mount_standard_filesystems() != 0) return 125;
    if (restrict_capabilities() != 0) return 125;
    if (setgroups(0, NULL) != 0) return fail("clear supplementary groups");
    if (setgid(gid) != 0) return fail("setgid");
    if (setuid(uid) != 0) return fail("setuid");
    if (chdir(argv[2]) != 0) return fail("chdir working directory");
    if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) return fail("close inherited descriptors");
    execvp(argv[5 + volume_count * 3], argv + 5 + volume_count * 3);
    return fail("exec");
}

int main(int argc, char **argv) {
    if (argc < 6) {
        fputs("rift-exec: missing command\n", stderr);
        return 125;
    }
    char *end;
    errno = 0;
    unsigned long volume_count = strtoul(argv[4], &end, 10);
    if (errno || *end || volume_count > 16 || argc < 6 + (int)volume_count * 3 || !argv[5 + volume_count * 3][0]) {
        fputs("rift-exec: invalid volume count or missing command\n", stderr);
        return 125;
    }
    if (unshare(CLONE_NEWNS | CLONE_NEWPID) != 0) return fail("create container namespaces");
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return fail("make mounts private");
    pid_t child = fork();
    if (child < 0) return fail("fork container process");
    if (child == 0) return run_container(argv, volume_count);

    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return fail("wait for container process");
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}
