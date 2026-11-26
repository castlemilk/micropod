#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#import <stdio.h>
#import <stdlib.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:atoi(argv[1])
                                                                closeOnDealloc:NO];
        __attribute__((objc_precise_lifetime))
        VZFileHandleNetworkDeviceAttachment *attachment =
            [[VZFileHandleNetworkDeviceAttachment alloc] initWithFileHandle:handle];
        attachment.maximumTransmissionUnit = atoi(argv[2]);
        printf("%ld %d\n", (long)attachment.maximumTransmissionUnit,
               attachment.fileHandle.fileDescriptor);
        fflush(stdout);
        return getchar() == 'q' ? 0 : 1;
    }
}
