#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phone cluster worker on iOS: serves this device's GPU (Metal) to a
/// master phone over llama.cpp's RPC protocol. Mirrors the Android worker
/// (ClusterWorkerService / jni_wrapper.cpp).
///
/// ggml's RPC server can't be stopped, and iOS has no separate worker
/// process to end, so once started it runs until the app closes.
@interface LlamaClusterWorker : NSObject

/// Starts serving on 0.0.0.0:`port` in a background thread. Returns nil on
/// success, or why it couldn't start.
+ (nullable NSString*)startOnPort:(int)port
                          threads:(int)threads
                         cacheDir:(NSString*)cacheDir;

+ (BOOL)isRunning;

/// Why the server stopped, if it started and then exited.
+ (nullable NSString*)lastError;

/// Address of the master using this worker right now, or nil.
+ (nullable NSString*)connectedPeer;

/// Memory this app may still use before iOS ends it, in MB.
+ (long)availableMemoryMb;

/// Memory this app uses now (its footprint), in MB.
+ (long)footprintMb;

/// Memory read speed in GB/s (~0.2 s).
+ (double)memoryBandwidthWithThreads:(int)threads;

@end

NS_ASSUME_NONNULL_END
