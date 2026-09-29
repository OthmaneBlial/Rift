#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

typedef struct RiftForwarder RiftForwarder;
extern RiftForwarder *rift_forward_start(const char *control_path, uint16_t host_port, uint16_t guest_port);
extern void rift_forward_stop(RiftForwarder *forwarder);
typedef struct { const char *path; int read_only; } RiftShare;

int rift_vm_validate_resources(size_t cpu_count, uint64_t memory_size) {
    @autoreleasepool {
        if (![NSThread isMainThread] || ![VZVirtualMachine isSupported]) return 2;
        if (cpu_count < VZVirtualMachineConfiguration.minimumAllowedCPUCount ||
            cpu_count > VZVirtualMachineConfiguration.maximumAllowedCPUCount ||
            memory_size < VZVirtualMachineConfiguration.minimumAllowedMemorySize ||
            memory_size > VZVirtualMachineConfiguration.maximumAllowedMemorySize ||
            memory_size % (1024 * 1024) != 0) return 6;
        return 0;
    }
}

static int request_guest_stop(const char *control_path) {
    char path[PATH_MAX];
    const int length = snprintf(path, sizeof(path), "%s/stop", control_path);
    if (length < 0 || length >= (int)sizeof(path)) return -1;
    const int descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
    if (descriptor < 0) return -1;
    return close(descriptor);
}

static int write_guest_measurement_ms(const char *control_path, const char *name, double milliseconds) {
    char temporary_path[PATH_MAX];
    char result_path[PATH_MAX];
    int temporary_length = snprintf(temporary_path, sizeof(temporary_path), "%s/%s.tmp", control_path, name);
    int result_length = snprintf(result_path, sizeof(result_path), "%s/%s", control_path, name);
    if (temporary_length < 0 || temporary_length >= (int)sizeof(temporary_path) ||
        result_length < 0 || result_length >= (int)sizeof(result_path)) return -1;
    int descriptor = open(temporary_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return -1;
    char value[32];
    int length = snprintf(value, sizeof(value), "%.3f\n", milliseconds);
    ssize_t written = length > 0 && length < (int)sizeof(value) ? write(descriptor, value, (size_t)length) : -1;
    int close_result = close(descriptor);
    if (written != length || close_result != 0 || rename(temporary_path, result_path) != 0) {
        unlink(temporary_path);
        return -1;
    }
    return 0;
}

static int record_guest_marker_ms(const char *control_path, const char *marker, const char *result,
                                  const struct timespec *started) {
    char ready_path[PATH_MAX];
    int ready_length = snprintf(ready_path, sizeof(ready_path), "%s/%s", control_path, marker);
    if (ready_length < 0 || ready_length >= (int)sizeof(ready_path)) return -1;
    if (access(ready_path, F_OK) != 0) return errno == ENOENT ? 0 : -1;
    struct timespec finished;
    if (clock_gettime(CLOCK_MONOTONIC, &finished) != 0) return -1;
    double milliseconds = (finished.tv_sec - started->tv_sec) * 1000.0 +
        (finished.tv_nsec - started->tv_nsec) / 1000000.0;
    return write_guest_measurement_ms(control_path, result, milliseconds) == 0 ? 1 : -1;
}

@interface RiftVMDelegate : NSObject <VZVirtualMachineDelegate>
@property(nonatomic) BOOL finished;
@property(nonatomic) int result;
@end

@implementation RiftVMDelegate
- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)virtualMachine {
    self.finished = YES;
    self.result = 0;
}

- (void)virtualMachine:(VZVirtualMachine *)virtualMachine didStopWithError:(NSError *)error {
    fprintf(stderr, "rift-vm: guest stopped: %s\n", error.description.UTF8String);
    self.finished = YES;
    self.result = 1;
}
@end

int rift_vm_run(const char *kernel_path, const char *initramfs_path, const char *command_line,
                const char *share_path, const char *control_path, const char *stop_path, const char *kill_path,
                const RiftShare *volumes, size_t volume_count, int network_enabled, int measure_guest_boot,
                int host_port, int guest_port, size_t cpu_count, uint64_t memory_size, int input_fd, int output_fd) {
    @autoreleasepool {
        if (![NSThread isMainThread] || ![VZVirtualMachine isSupported]) return 2;
        if (!kernel_path || !initramfs_path || !command_line || input_fd < 0 || output_fd < 0) return 1;
        if (volume_count > 16 || (volume_count != 0 && !volumes)) return 1;
        int resource_status = rift_vm_validate_resources(cpu_count, memory_size);
        if (resource_status != 0) return resource_status;
        if ((host_port != 0 || guest_port != 0) && (!network_enabled || !control_path || host_port < 1 || host_port > 65535 || guest_port < 1 || guest_port > 65535)) return 1;
        if (stop_path && !control_path) return 1;
        if (measure_guest_boot && !control_path) return 1;

        NSString *kernel = [NSString stringWithUTF8String:kernel_path];
        NSString *initramfs = [NSString stringWithUTF8String:initramfs_path];
        NSString *arguments = [NSString stringWithUTF8String:command_line];
        if (!kernel || !initramfs || !arguments) return 1;

        VZLinuxBootLoader *boot = [[VZLinuxBootLoader alloc] initWithKernelURL:[NSURL fileURLWithPath:kernel]];
        boot.initialRamdiskURL = [NSURL fileURLWithPath:initramfs];
        boot.commandLine = arguments;

        NSFileHandle *input = [[NSFileHandle alloc] initWithFileDescriptor:input_fd closeOnDealloc:NO];
        NSFileHandle *output = [[NSFileHandle alloc] initWithFileDescriptor:output_fd closeOnDealloc:NO];
        VZVirtioConsoleDeviceSerialPortConfiguration *serial = [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        serial.attachment = [[VZFileHandleSerialPortAttachment alloc] initWithFileHandleForReading:input
                                                            fileHandleForWriting:output];

        VZVirtualMachineConfiguration *config = [[VZVirtualMachineConfiguration alloc] init];
        config.CPUCount = cpu_count;
        config.memorySize = memory_size;
        config.bootLoader = boot;
        config.platform = [[VZGenericPlatformConfiguration alloc] init];
        config.serialPorts = @[serial];
        if (control_path && !share_path) return 1;
        NSMutableArray<VZDirectorySharingDeviceConfiguration *> *shares = [NSMutableArray array];
        if (share_path) {
            NSString *path = [NSString stringWithUTF8String:share_path];
            if (!path) return 1;
            VZSharedDirectory *directory = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                                   readOnly:YES];
            VZVirtioFileSystemDeviceConfiguration *filesystem =
                [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:@"rift-rootfs"];
            filesystem.share = [[VZSingleDirectoryShare alloc] initWithDirectory:directory];
            [shares addObject:filesystem];
        }
        if (control_path) {
            NSString *path = [NSString stringWithUTF8String:control_path];
            if (!path) return 1;
            VZSharedDirectory *directory = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                                   readOnly:NO];
            VZVirtioFileSystemDeviceConfiguration *filesystem =
                [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:@"rift-control"];
            filesystem.share = [[VZSingleDirectoryShare alloc] initWithDirectory:directory];
            [shares addObject:filesystem];
        }
        for (size_t index = 0; index < volume_count; ++index) {
            if (!volumes[index].path) return 1;
            NSString *path = [NSString stringWithUTF8String:volumes[index].path];
            if (!path) return 1;
            VZSharedDirectory *directory = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                                   readOnly:volumes[index].read_only != 0];
            NSString *tag = [NSString stringWithFormat:@"rift-volume-%zu", index];
            VZVirtioFileSystemDeviceConfiguration *filesystem =
                [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:tag];
            filesystem.share = [[VZSingleDirectoryShare alloc] initWithDirectory:directory];
            [shares addObject:filesystem];
        }
        config.directorySharingDevices = shares;
        if (network_enabled) {
            VZVirtioNetworkDeviceConfiguration *network = [[VZVirtioNetworkDeviceConfiguration alloc] init];
            network.attachment = [[VZNATNetworkDeviceAttachment alloc] init];
            config.networkDevices = @[network];
        }
        NSError *error = nil;
        if (![config validateWithError:&error]) {
            fprintf(stderr, "rift-vm: invalid configuration: %s\n", error.description.UTF8String);
            return 1;
        }

        RiftForwarder *forwarder = NULL;
        if (host_port) {
            forwarder = rift_forward_start(control_path, (uint16_t)host_port, (uint16_t)guest_port);
            if (!forwarder) return 3;
        }

        VZVirtualMachine *machine = [[VZVirtualMachine alloc] initWithConfiguration:config];
        RiftVMDelegate *delegate = [[RiftVMDelegate alloc] init];
        machine.delegate = delegate;
        struct timespec guestBootStarted = {0};
        if (measure_guest_boot && clock_gettime(CLOCK_MONOTONIC, &guestBootStarted) != 0) return 1;
        [machine startWithCompletionHandler:^(NSError *start_error) {
            if (start_error) {
                fprintf(stderr, "rift-vm: start failed: %s\n", start_error.description.UTF8String);
                delegate.finished = YES;
                delegate.result = 1;
            }
        }];
        BOOL stopRequested = NO;
        BOOL killRequested = NO;
        BOOL forceStopRequested = NO;
        __block BOOL stopFailed = NO;
        NSTimeInterval stopRequestedAt = 0;
        BOOL guestBootMeasured = NO;
        BOOL guestBootMeasurementFailed = NO;
        BOOL guestNetworkStartMeasured = NO;
        BOOL guestNetworkStartMeasurementFailed = NO;
        BOOL guestNetworkReadyMeasured = NO;
        BOOL guestNetworkReadyMeasurementFailed = NO;
        while (!delegate.finished) {
            if (measure_guest_boot && !guestBootMeasured) {
                int result = record_guest_marker_ms(control_path, "guest-boot-ready", "guest-boot-ms", &guestBootStarted);
                if (result != 0) {
                    guestBootMeasurementFailed = result < 0;
                    guestBootMeasured = YES;
                }
            }
            if (measure_guest_boot && !guestNetworkStartMeasured) {
                int result = record_guest_marker_ms(control_path, "guest-network-start-ready", "guest-network-start-ms", &guestBootStarted);
                if (result != 0) {
                    guestNetworkStartMeasurementFailed = result < 0;
                    guestNetworkStartMeasured = YES;
                }
            }
            if (measure_guest_boot && !guestNetworkReadyMeasured) {
                int result = record_guest_marker_ms(control_path, "guest-network-ready", "guest-network-ready-ms", &guestBootStarted);
                if (result != 0) {
                    guestNetworkReadyMeasurementFailed = result < 0;
                    guestNetworkReadyMeasured = YES;
                }
            }
            if (stop_path && !stopRequested && access(stop_path, F_OK) == 0 && machine.state == VZVirtualMachineStateRunning) {
                stopRequested = YES;
                stopRequestedAt = NSProcessInfo.processInfo.systemUptime;
                if (request_guest_stop(control_path) != 0) {
                    fprintf(stderr, "rift-vm: could not notify guest to stop\n");
                    stopRequestedAt -= 10.0;
                }
            }
            if (kill_path && !killRequested && access(kill_path, F_OK) == 0 && machine.state == VZVirtualMachineStateRunning) {
                killRequested = YES;
            }
            if (!forceStopRequested && machine.state == VZVirtualMachineStateRunning &&
                (killRequested || (stopRequested && NSProcessInfo.processInfo.systemUptime - stopRequestedAt >= 10.0))) {
                forceStopRequested = YES;
                [machine stopWithCompletionHandler:^(NSError *stop_error) {
                    if (stop_error) {
                        fprintf(stderr, "rift-vm: stop failed: %s\n", stop_error.description.UTF8String);
                        stopFailed = YES;
                    }
                    delegate.finished = YES;
                    delegate.result = stop_error ? 1 : 0;
                }];
            }
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:measure_guest_boot && !guestBootMeasured ? 0.01 : 0.1]];
        }
        machine.delegate = nil;
        rift_forward_stop(forwarder);
        if (measure_guest_boot && (!guestBootMeasured || guestBootMeasurementFailed ||
                                   !guestNetworkStartMeasured || guestNetworkStartMeasurementFailed ||
                                   !guestNetworkReadyMeasured || guestNetworkReadyMeasurementFailed)) {
            fprintf(stderr, "rift-vm: guest startup measurements did not complete\n");
            return 1;
        }
        if (killRequested && !stopFailed && delegate.result == 0) return 5;
        return stopRequested && !stopFailed && delegate.result == 0 ? 4 : delegate.result;
    }
}
