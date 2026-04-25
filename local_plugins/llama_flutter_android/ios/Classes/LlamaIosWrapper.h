#ifndef LlamaIosWrapper_h
#define LlamaIosWrapper_h

#import <Foundation/Foundation.h>

typedef void (^LlamaTokenCallback)(NSString* _Nonnull token);
typedef void (^LlamaProgressCallback)(double progress);

NS_ASSUME_NONNULL_BEGIN

@interface LlamaIosWrapper : NSObject

/// Load a GGUF model file. Throws NSException on failure.
- (void)loadModelAtPath:(NSString*)path
               nThreads:(int)nThreads
            contextSize:(int)contextSize
             nGpuLayers:(int)nGpuLayers
       progressCallback:(LlamaProgressCallback)progressCallback;

/// Start text generation. Calls tokenCallback for each token synchronously (runs on caller thread).
- (void)generateWithPrompt:(NSString*)prompt
                 maxTokens:(int)maxTokens
               temperature:(double)temperature
                      topP:(double)topP
                      topK:(int)topK
                      minP:(double)minP
                  typicalP:(double)typicalP
             repeatPenalty:(double)repeatPenalty
         frequencyPenalty:(double)frequencyPenalty
          presencePenalty:(double)presencePenalty
              repeatLastN:(int)repeatLastN
                 mirostat:(int)mirostat
              mirostatTau:(double)mirostatTau
              mirostatEta:(double)mirostatEta
                     seed:(long long)seed
         penalizeNewline:(BOOL)penalizeNewline
            tokenCallback:(LlamaTokenCallback)tokenCallback;

/// Signal the current generation to stop.
- (void)stop;

/// Free model and context resources.
- (void)freeModel;

/// Returns YES if a model is currently loaded.
- (BOOL)isModelLoaded;

/// Returns number of tokens currently in KV cache.
- (int)tokensUsed;

/// Returns context window size.
- (int)contextSize;

/// Resets the KV cache (clears conversation history, keeps model loaded).
- (void)clearContext;

/// Sets system prompt length for smart context management.
- (void)setSystemPromptLength:(int)length;

@end

NS_ASSUME_NONNULL_END

#endif /* LlamaIosWrapper_h */
