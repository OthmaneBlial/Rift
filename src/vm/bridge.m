#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>

typedef struct RiftForwarder RiftForwarder;
extern RiftForwarder *rift_forward_start(const char *control_path, uint16_t host_port, uint16_t guest_port);
extern void rift_forward_stop(RiftForwarder *forwarder);

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
                const char *share_path, const char *control_path, const char *stop_path, int network_enabled,
                int host_port, int guest_port, int input_fd, int output_fd) {
    @autoreleasepool {
        if (![NSThread isMainThread] || ![VZVirtualMachine isSupported]) return 2;
        if (!kernel_path || !initramfs_path || !command_line || input_fd < 0 || output_fd < 0) return 1;
        if ((host_port != 0 || guest_port != 0) && (!network_enabled || !control_path || host_port < 1 || host_port > 65535 || guest_port < 1 || guest_port > 65535)) return 1;

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
        config.CPUCount = 2;
        config.memorySize = 512 * 1024 * 1024;
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
        [machine startWithCompletionHandler:^(NSError *start_error) {
            if (start_error) {
                fprintf(stderr, "rift-vm: start failed: %s\n", start_error.description.UTF8String);
                delegate.finished = YES;
                delegate.result = 1;
            }
        }];
        BOOL stopRequested = NO;
        __block BOOL stopFailed = NO;
        while (!delegate.finished) {
            if (stop_path && !stopRequested && access(stop_path, F_OK) == 0 && machine.state == VZVirtualMachineStateRunning) {
                stopRequested = YES;
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
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        machine.delegate = nil;
        rift_forward_stop(forwarder);
        return stopRequested && !stopFailed && delegate.result == 0 ? 4 : delegate.result;
    }
}
