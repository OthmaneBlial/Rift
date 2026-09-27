#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include <stdio.h>

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
                int input_fd, int output_fd) {
    @autoreleasepool {
        if (![NSThread isMainThread] || ![VZVirtualMachine isSupported]) return 2;
        if (!kernel_path || !initramfs_path || !command_line || input_fd < 0 || output_fd < 0) return 1;

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
        NSError *error = nil;
        if (![config validateWithError:&error]) {
            fprintf(stderr, "rift-vm: invalid configuration: %s\n", error.description.UTF8String);
            return 1;
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
        while (!delegate.finished) {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        machine.delegate = nil;
        return delegate.result;
    }
}
