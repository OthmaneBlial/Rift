#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
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
    if (setgroups(0, NULL) != 0) return fail("clear supplementary groups");
    if (setgid(gid) != 0) return fail("setgid");
    if (setuid(uid) != 0) return fail("setuid");
    if (chdir(argv[2]) != 0) return fail("chdir working directory");
    execvp(argv[5 + volume_count * 3], argv + 5 + volume_count * 3);
    return fail("exec");
}
