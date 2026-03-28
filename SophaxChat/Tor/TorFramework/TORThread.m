//
//  TORThread.m
//  Tor
//
//  Created by Conrad Kramer on 7/19/15.
//

#import "TORThread.h"
#import "TORConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

// When the tor.xcframework binary is not present (development builds without the framework
// binary), this stub compiles successfully. TorManager will time out waiting for the control
// socket and transition to .failed("Control socket timeout") — acceptable for local dev.
#if __has_include(<feature/api/tor_api.h>)

#import <feature/api/tor_api.h>
#import "TORLogging.h"

static __weak TORThread *_thread = nil;

@interface TORThread ()
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *arguments;
@end

@implementation TORThread

+ (nullable TORThread *)activeThread { return _thread; }

- (instancetype)init { return [self initWithArguments:nil]; }

- (instancetype)initWithConfiguration:(nullable TORConfiguration *)configuration {
    return [self initWithArguments:[configuration compile]];
}

- (instancetype)initWithArguments:(nullable NSArray<NSString *> *)arguments {
    NSAssert(_thread == nil, @"There can only be one TORThread per process");
    self = [super init];
    if (!self) return nil;
    _thread = self;
    _arguments = [arguments copy];
    self.name = @"Tor";
    return self;
}

- (void)main {
    NSArray *arguments = self.arguments;
    int argc = (int)(arguments.count + 1);
    char *argv[argc];
    argv[0] = "tor";
    for (NSUInteger idx = 0; idx < arguments.count; idx++)
        argv[idx + 1] = (char *)[arguments[idx] UTF8String];
    argv[argc] = NULL;

    tor_main_configuration_t *cfg = tor_main_configuration_new();
    tor_main_configuration_set_command_line(cfg, argc, argv);
    tor_run_main(cfg);
    tor_main_configuration_free(cfg);
}

@end

#else // Framework binary not available — provide no-op stub for local development builds

static __weak TORThread *_thread = nil;

@interface TORThread ()
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *arguments;
@end

@implementation TORThread

+ (nullable TORThread *)activeThread { return _thread; }

- (instancetype)init { return [self initWithArguments:nil]; }

- (instancetype)initWithConfiguration:(nullable TORConfiguration *)configuration {
    return [self initWithArguments:nil];
}

- (instancetype)initWithArguments:(nullable NSArray<NSString *> *)arguments {
    self = [super init];
    if (!self) return nil;
    _thread = self;
    _arguments = [arguments copy];
    self.name = @"Tor";
    return self;
}

- (void)main {
    // Tor binary not available — no-op stub. TorManager will time out on control socket.
}

@end

#endif // __has_include(<feature/api/tor_api.h>)

NS_ASSUME_NONNULL_END
