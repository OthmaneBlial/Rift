#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static const int handled_signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGWINCH};
static struct sigaction previous_actions[sizeof(handled_signals) / sizeof(handled_signals[0])];
static size_t installed_actions;
static struct termios previous_terminal;
static int terminal_saved;
static int terminal_active;
static volatile sig_atomic_t pending_signal;
static volatile sig_atomic_t pending_signal_count;
static volatile sig_atomic_t pending_resize;

static void record_signal(int signal_number) {
    if (signal_number == SIGWINCH) {
        pending_resize = 1;
    } else {
        pending_signal = signal_number;
        if (pending_signal_count < 2) pending_signal_count++;
    }
}

static void restore_actions(void) {
    while (installed_actions) {
        --installed_actions;
        sigaction(handled_signals[installed_actions], &previous_actions[installed_actions], NULL);
    }
}

int rift_exec_terminal_start(int with_tty) {
    if (terminal_active || (with_tty && (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)))) {
        errno = ENOTTY;
        return -1;
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = record_signal;
    sigfillset(&action.sa_mask);
    const size_t signal_count = with_tty ? sizeof(handled_signals) / sizeof(handled_signals[0]) : 4;
    while (installed_actions < signal_count) {
        if (sigaction(handled_signals[installed_actions], &action, &previous_actions[installed_actions]) != 0) {
            restore_actions();
            return -1;
        }
        installed_actions++;
    }
    if (with_tty) {
        struct termios raw;
        if (tcgetattr(STDIN_FILENO, &previous_terminal) != 0) {
            restore_actions();
            return -1;
        }
        raw = previous_terminal;
        cfmakeraw(&raw);
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) {
            restore_actions();
            return -1;
        }
        terminal_saved = 1;
    }
    pending_signal = 0;
    pending_signal_count = 0;
    pending_resize = 0;
    terminal_active = 1;
    return 0;
}

void rift_exec_terminal_stop(void) {
    if (terminal_saved) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &previous_terminal);
        terminal_saved = 0;
    }
    restore_actions();
    pending_signal = 0;
    pending_signal_count = 0;
    pending_resize = 0;
    terminal_active = 0;
}

int rift_exec_terminal_take_signal(void) {
    if (pending_signal_count == 0) return 0;
    pending_signal_count--;
    return pending_signal;
}

int rift_exec_terminal_take_resize(void) {
    int resized = pending_resize;
    pending_resize = 0;
    return resized;
}

int rift_exec_terminal_size(uint16_t *rows, uint16_t *columns) {
    if (!rows || !columns) {
        errno = EINVAL;
        return -1;
    }
    struct winsize size;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) != 0) return -1;
    *rows = size.ws_row ? size.ws_row : 24;
    *columns = size.ws_col ? size.ws_col : 80;
    return 0;
}

ssize_t rift_exec_terminal_read(unsigned char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) {
        errno = EINVAL;
        return -1;
    }
    sigset_t block;
    sigset_t previous;
    sigemptyset(&block);
    for (size_t index = 0; index < sizeof(handled_signals) / sizeof(handled_signals[0]); ++index)
        sigaddset(&block, handled_signals[index]);
    if (sigprocmask(SIG_BLOCK, &block, &previous) != 0) return -1;

    struct pollfd descriptor = {.fd = STDIN_FILENO, .events = POLLIN};
    const int ready = poll(&descriptor, 1, 0);
    ssize_t result = -2;
    if (ready < 0 && errno != EINTR) {
        result = -1;
    } else if (ready > 0 && (descriptor.revents & (POLLIN | POLLHUP))) {
        result = read(STDIN_FILENO, buffer, capacity);
        if (result < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) result = -2;
    }
    const int read_errno = errno;
    if (sigprocmask(SIG_SETMASK, &previous, NULL) != 0) return -1;
    errno = read_errno;
    return result;
}
