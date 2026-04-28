#import <Foundation/Foundation.h>

@interface SdIosWrapper : NSObject

- (BOOL)initModel:(NSString *)path;
- (NSData *)generateImage:(NSString *)prompt steps:(int)steps;
- (void)unloadModel;

@end
