#import <AppKit/AppKit.h>

// Activate only the profile process; no Accessibility or screen capture.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSRunningApplication *application =
            [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)atoi(argv[1])];
        BOOL requested = [application activateWithOptions:0];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (requested && !application.active && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        printf("{\"requested\":%s,\"active\":%s}\n",
            requested ? "true" : "false", application.active ? "true" : "false");
        return application.active ? 0 : 1;
    }
}
