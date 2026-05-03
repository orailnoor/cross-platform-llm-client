//
//  LiteLmNativeBridge.mm
//  flutter_litert_lm
//
//  Objective-C++ implementation that calls the LiteRT-LM C API from engine.h
//  (shipped inside LiteRTLM.xcframework).
//

#import "LiteLmNativeBridge.h"

// LiteRTLM is a framework module built from the vendored xcframework.
#import <LiteRTLM/engine.h>

static NSError *MakeError(NSString *message) {
    return [NSError errorWithDomain:@"LiteLmNativeBridge"
                               code:-1
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

/// Redirect the process's stderr to a temp file, run [block], then restore
/// stderr and return whatever was captured. LiteRT-LM writes its error
/// messages via absl logging → fprintf(stderr), which doesn't go through
/// os_log, so we have to swap the file descriptor ourselves to surface
/// them as an NSError message.
static NSString *CaptureStderrDuring(NSString *tempName, void (^block)(void)) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];
    int savedStderr = dup(STDERR_FILENO);
    FILE *newErr = freopen([path UTF8String], "w+", stderr);
    (void)newErr;

    block();

    fflush(stderr);
    dup2(savedStderr, STDERR_FILENO);
    close(savedStderr);

    NSString *captured = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    return captured ?: @"";
}

@implementation LiteLmNativeBridge

+ (void)setMinLogLevel:(int)level {
    litert_lm_set_min_log_level(level);
}

- (NSValue *)createEngineWithModelPath:(NSString *)modelPath
                               backend:(NSString *)backend
                         visionBackend:(NSString *)visionBackend
                          audioBackend:(NSString *)audioBackend
                              cacheDir:(NSString *)cacheDir
                                 error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:modelPath]) {
        if (error) *error = MakeError([NSString stringWithFormat:
            @"Model file not found at: %@", modelPath]);
        return nil;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:modelPath error:nil];

    const char *cModelPath = [modelPath UTF8String];
    const char *cBackend = [backend UTF8String];
    const char *cVision = visionBackend ? [visionBackend UTF8String] : NULL;
    const char *cAudio = audioBackend ? [audioBackend UTF8String] : NULL;

    LiteRtLmEngineSettings *settings = litert_lm_engine_settings_create(
        cModelPath, cBackend, cVision, cAudio);
    if (!settings) {
        if (error) *error = MakeError(@"litert_lm_engine_settings_create returned NULL");
        return nil;
    }

    if (cacheDir) {
        litert_lm_engine_settings_set_cache_dir(settings, [cacheDir UTF8String]);
    }

    __block LiteRtLmEngine *engine = NULL;
    NSString *capturedErr = CaptureStderrDuring(@"litert_engine_stderr.log", ^{
        engine = litert_lm_engine_create(settings);
    });
    litert_lm_engine_settings_delete(settings);

    if (!engine) {
        if (error) {
            NSString *suffix = capturedErr.length > 0
                ? [NSString stringWithFormat:@"\nNative log:\n%@", capturedErr]
                : @"";
            *error = MakeError([NSString stringWithFormat:
                @"litert_lm_engine_create returned NULL. "
                @"Model file (%@ bytes) exists and is readable, but the engine "
                @"failed to load it.%@",
                attrs[NSFileSize], suffix]);
        }
        return nil;
    }

    return [NSValue valueWithPointer:(const void *)engine];
}

- (void)deleteEngine:(NSValue *)engineHandle {
    if (!engineHandle) return;
    LiteRtLmEngine *engine = (LiteRtLmEngine *)[engineHandle pointerValue];
    if (engine) litert_lm_engine_delete(engine);
}

- (NSValue *)createConversationWithEngine:(NSValue *)engineHandle
                        systemInstruction:(NSString *)systemInstruction
                                     topK:(int)topK
                                     topP:(float)topP
                              temperature:(float)temperature
                                    error:(NSError **)error {
    LiteRtLmEngine *engine = (LiteRtLmEngine *)[engineHandle pointerValue];
    if (!engine) {
        if (error) *error = MakeError(@"Engine handle is NULL");
        return nil;
    }

    // Note: the LiteRT-LM iOS build we ship does not implement the kTopK (1)
    // or kGreedy (3) samplers — they fail with "UNIMPLEMENTED: Sampler type: N
    // not implemented yet". Passing NULL here makes the engine fall back to
    // whatever sampler is baked into the model's own metadata, which is the
    // only combination that reliably works right now. The Dart-side sampler
    // knobs (topK/topP/temperature) are therefore ignored on iOS for now.
    LiteRtLmSessionConfig *sessionConfig = NULL;

    NSString *systemJson = nil;
    if (systemInstruction.length > 0) {
        NSDictionary *obj = @{ @"role": @"system", @"content": systemInstruction };
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
        systemJson = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }

    __block LiteRtLmConversationConfig *convConfig = NULL;
    __block LiteRtLmConversation *conversation = NULL;
    NSString *capturedErr = CaptureStderrDuring(@"litert_conv_stderr.log", ^{
        convConfig = litert_lm_conversation_config_create(
            engine,
            sessionConfig,
            systemJson ? [systemJson UTF8String] : NULL,
            NULL, // tools_json
            NULL, // messages_json
            false // enable_constrained_decoding
        );
        conversation = litert_lm_conversation_create(engine, convConfig);
    });

    if (convConfig) litert_lm_conversation_config_delete(convConfig);
    if (sessionConfig) litert_lm_session_config_delete(sessionConfig);

    if (!conversation) {
        if (error) {
            NSString *suffix = capturedErr.length > 0
                ? [NSString stringWithFormat:@"\nNative log:\n%@", capturedErr]
                : @"";
            *error = MakeError([NSString stringWithFormat:
                @"litert_lm_conversation_create returned NULL.%@", suffix]);
        }
        return nil;
    }

    return [NSValue valueWithPointer:(const void *)conversation];
}

- (void)deleteConversation:(NSValue *)conversationHandle {
    if (!conversationHandle) return;
    LiteRtLmConversation *conv = (LiteRtLmConversation *)[conversationHandle pointerValue];
    if (conv) litert_lm_conversation_delete(conv);
}

- (NSString *)sendMessage:(NSString *)messageJson
           toConversation:(NSValue *)conversationHandle
             extraContext:(NSString *)extraContext
                    error:(NSError **)error {
    LiteRtLmConversation *conv = (LiteRtLmConversation *)[conversationHandle pointerValue];
    if (!conv) {
        if (error) *error = MakeError(@"Conversation handle is NULL");
        return nil;
    }

    const char *cMsg = [messageJson UTF8String];
    const char *cExtra = extraContext ? [extraContext UTF8String] : NULL;

    LiteRtLmJsonResponse *response = litert_lm_conversation_send_message(conv, cMsg, cExtra);
    if (!response) {
        if (error) *error = MakeError(@"litert_lm_conversation_send_message returned NULL");
        return nil;
    }

    const char *cResponse = litert_lm_json_response_get_string(response);
    NSString *result = cResponse ? [NSString stringWithUTF8String:cResponse] : @"";
    litert_lm_json_response_delete(response);
    return result;
}

// --- Streaming ---

struct StreamContext {
    void (^onChunk)(NSString *);
    void (^onComplete)(NSError *);
};

static void StreamTrampoline(void *callback_data,
                             const char *chunk,
                             bool is_final,
                             const char *error_msg) {
    StreamContext *ctx = (StreamContext *)callback_data;
    if (!ctx) return;

    if (error_msg) {
        NSError *err = MakeError([NSString stringWithUTF8String:error_msg]);
        if (ctx->onComplete) ctx->onComplete(err);
        delete ctx;
        return;
    }

    if (chunk && ctx->onChunk) {
        NSString *chunkStr = [NSString stringWithUTF8String:chunk];
        ctx->onChunk(chunkStr);
    }

    if (is_final) {
        if (ctx->onComplete) ctx->onComplete(nil);
        delete ctx;
    }
}

- (void)sendMessageStream:(NSString *)messageJson
           toConversation:(NSValue *)conversationHandle
             extraContext:(NSString *)extraContext
                  onChunk:(void (^)(NSString *chunk))onChunk
               onComplete:(void (^)(NSError * _Nullable error))onComplete {
    LiteRtLmConversation *conv = (LiteRtLmConversation *)[conversationHandle pointerValue];
    if (!conv) {
        onComplete(MakeError(@"Conversation handle is NULL"));
        return;
    }

    StreamContext *ctx = new StreamContext();
    ctx->onChunk = [onChunk copy];
    ctx->onComplete = [onComplete copy];

    int rc = litert_lm_conversation_send_message_stream(
        conv,
        [messageJson UTF8String],
        extraContext ? [extraContext UTF8String] : NULL,
        &StreamTrampoline,
        ctx
    );

    if (rc != 0) {
        delete ctx;
        onComplete(MakeError([NSString stringWithFormat:
            @"litert_lm_conversation_send_message_stream failed rc=%d", rc]));
    }
}

@end
