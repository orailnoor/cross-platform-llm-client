#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>
#include "stable-diffusion.h"

#define TAG "SD_JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static sd_ctx_t* g_sd_ctx = nullptr;
static JavaVM* g_jvm = nullptr;
static jobject g_progress_callback = nullptr;

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

void sd_log_cb(enum sd_log_level_t level, const char* text, void* data) {
    LOGI("[SD Core] %s", text);
}

void sd_progress_cb(int step, int steps, float time, void* data) {
    if (g_progress_callback && g_jvm) {
        JNIEnv* env;
        jint attachStatus = g_jvm->GetEnv((void**)&env, JNI_VERSION_1_6);
        if (attachStatus == JNI_EDETACHED) {
            if (g_jvm->AttachCurrentThread(&env, nullptr) != 0) {
                return;
            }
        } else if (attachStatus != JNI_OK) {
            return;
        }
        jclass clazz = env->GetObjectClass(g_progress_callback);
        if (clazz) {
            jmethodID method = env->GetMethodID(clazz, "onProgress", "(II)V");
            if (method) {
                env->CallVoidMethod(g_progress_callback, method, (jint)step, (jint)steps);
            }
        }
        // Note: we don't detach here because generate_image may call this
        // multiple times. The thread will be detached when the JVM exits
        // or the native method returns (for threads attached by AttachCurrentThread).
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_sd_1flutter_1android_SdFlutterAndroidPlugin_initModel(
    JNIEnv* env, jobject thiz, jstring model_path) {
    
    if (g_sd_ctx) {
        free_sd_ctx(g_sd_ctx);
        g_sd_ctx = nullptr;
    }

    const char* path = env->GetStringUTFChars(model_path, nullptr);
    
    sd_set_log_callback(sd_log_cb, nullptr);
    sd_set_progress_callback(sd_progress_cb, nullptr);

    sd_ctx_params_t params;
    sd_ctx_params_init(&params);
    params.model_path = path;
    params.n_threads = sd_get_num_physical_cores();
    
    LOGI("Initializing SD model from: %s", path);
    g_sd_ctx = new_sd_ctx(&params);
    
    env->ReleaseStringUTFChars(model_path, path);
    
    return g_sd_ctx != nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_example_sd_1flutter_1android_SdFlutterAndroidPlugin_generateImage(
    JNIEnv* env, jobject thiz, jstring prompt, jint steps, jobject callback) {
    
    if (!g_sd_ctx) {
        LOGE("SD context not initialized");
        return nullptr;
    }

    // Store callback as global ref so it remains valid across threads
    if (g_progress_callback) {
        env->DeleteGlobalRef(g_progress_callback);
    }
    g_progress_callback = env->NewGlobalRef(callback);

    const char* p_str = env->GetStringUTFChars(prompt, nullptr);
    
    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = p_str;
    params.sample_params.sample_steps = steps;
    params.width = 512;
    params.height = 512;
    params.sample_params.sample_method = EULER_A_SAMPLE_METHOD;

    LOGI("Generating image for prompt: %s", p_str);
    sd_image_t* result = generate_image(g_sd_ctx, &params);
    
    env->ReleaseStringUTFChars(prompt, p_str);

    if (g_progress_callback) {
        env->DeleteGlobalRef(g_progress_callback);
        g_progress_callback = nullptr;
    }

    if (!result) {
        LOGE("Generation failed");
        return nullptr;
    }

    size_t size = result->width * result->height * result->channel;
    jbyteArray array = env->NewByteArray(size);
    env->SetByteArrayRegion(array, 0, size, (jbyte*)result->data);
    
    free(result->data);
    free(result);

    return array;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_sd_1flutter_1android_SdFlutterAndroidPlugin_unloadModel(
    JNIEnv* env, jobject thiz) {
    if (g_sd_ctx) {
        free_sd_ctx(g_sd_ctx);
        g_sd_ctx = nullptr;
    }
    if (g_progress_callback) {
        env->DeleteGlobalRef(g_progress_callback);
        g_progress_callback = nullptr;
    }
}
