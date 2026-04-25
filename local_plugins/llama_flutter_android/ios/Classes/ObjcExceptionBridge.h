#import <Foundation/Foundation.h>

// Allows Swift to catch Objective-C exceptions thrown by LlamaIosWrapper.
NS_INLINE NSException* _Nullable tryBlock(void(^_Nonnull tryBlock)(void)) {
    @try { tryBlock(); }
    @catch (NSException* exception) { return exception; }
    return nil;
}
