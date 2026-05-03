//
//  LiteLmNativeBridge.h
//  flutter_lite_lm
//
//  Objective-C bridge over the LiteRT-LM C API. Exposed to Swift via the
//  plugin's umbrella header so the Swift plugin code doesn't need to import
//  the LiteRTLM Clang module directly (which CocoaPods doesn't auto-register
//  for vendored static-library xcframeworks).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LiteLmNativeBridge : NSObject

/// Set native log verbosity. 0=INFO, 1=WARNING, 2=ERROR, 3=FATAL.
+ (void)setMinLogLevel:(int)level;

/// Create and initialize an engine. Returns an opaque handle (NSValue-wrapped
/// pointer) or nil with error set.
- (nullable NSValue *)createEngineWithModelPath:(NSString *)modelPath
                                        backend:(NSString *)backend
                                  visionBackend:(nullable NSString *)visionBackend
                                   audioBackend:(nullable NSString *)audioBackend
                                       cacheDir:(nullable NSString *)cacheDir
                                          error:(NSError **)error;

- (void)deleteEngine:(NSValue *)engineHandle;

/// Create a conversation on the given engine. Returns an opaque handle.
- (nullable NSValue *)createConversationWithEngine:(NSValue *)engineHandle
                                  systemInstruction:(nullable NSString *)systemInstruction
                                               topK:(int)topK
                                               topP:(float)topP
                                        temperature:(float)temperature
                                              error:(NSError **)error;

- (void)deleteConversation:(NSValue *)conversationHandle;

/// Send a message (blocking). `messageJson` must be a JSON-encoded message
/// matching the LiteRT-LM conversation API format.
/// Returns the JSON response string on success, nil on failure.
- (nullable NSString *)sendMessage:(NSString *)messageJson
                    toConversation:(NSValue *)conversationHandle
                      extraContext:(nullable NSString *)extraContext
                             error:(NSError **)error;

/// Send a message and stream responses. The `onChunk` block receives each
/// chunk of text as the model generates it. `onComplete` fires once after the
/// final chunk (or on error).
- (void)sendMessageStream:(NSString *)messageJson
           toConversation:(NSValue *)conversationHandle
             extraContext:(nullable NSString *)extraContext
                  onChunk:(void (^)(NSString *chunk))onChunk
               onComplete:(void (^)(NSError * _Nullable error))onComplete;

@end

NS_ASSUME_NONNULL_END
