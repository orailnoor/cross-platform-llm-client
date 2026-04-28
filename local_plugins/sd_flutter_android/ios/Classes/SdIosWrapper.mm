#import "SdIosWrapper.h"
#include "stable-diffusion.h"

static sd_ctx_t* g_sd_ctx = nullptr;

@implementation SdIosWrapper

- (BOOL)initModel:(NSString *)path {
    if (g_sd_ctx) {
        free_sd_ctx(g_sd_ctx);
        g_sd_ctx = nullptr;
    }

    sd_ctx_params_t params;
    sd_ctx_params_init(&params);
    params.model_path = [path UTF8String];
    params.n_threads = sd_get_num_physical_cores();

    g_sd_ctx = new_sd_ctx(&params);
    return g_sd_ctx != nullptr;
}

- (NSData *)generateImage:(NSString *)prompt steps:(int)steps {
    if (!g_sd_ctx) return nil;

    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = [prompt UTF8String];
    params.sample_params.sample_steps = steps;
    params.width = 512;
    params.height = 512;
    params.sample_params.sample_method = EULER_A_SAMPLE_METHOD;

    sd_image_t* result = generate_image(g_sd_ctx, &params);

    if (!result) return nil;

    size_t size = result->width * result->height * result->channel;
    NSData *data = [NSData dataWithBytes:result->data length:size];

    free(result->data);
    free(result);

    return data;
}

- (void)unloadModel {
    if (g_sd_ctx) {
        free_sd_ctx(g_sd_ctx);
        g_sd_ctx = nullptr;
    }
}

@end
