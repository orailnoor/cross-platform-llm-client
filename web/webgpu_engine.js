// WebGPU Image Generation Engine for Flutter Web
// Uses HuggingFace Transformers.js with WebGPU backend
// On macOS/iOS Safari, WebGPU is implemented on top of Metal.

(function() {
    'use strict';

    let pipe = null;
    let isReady = false;
    let isInitializing = false;

    function log(msg) {
        console.log('[WebGPU Image]', msg);
        if (window.onWebGpuImageLog) {
            window.onWebGpuImageLog(msg);
        }
    }

    async function init() {
        if (isReady || isInitializing) return;
        isInitializing = true;

        log('Initializing WebGPU Image Engine...');

        try {
            const { pipeline } = await import('https://cdn.jsdelivr.net/npm/@xenova/transformers@2.17.2/dist/transformers.min.js');

            pipe = await pipeline('text-to-image', 'Xenova/dreamshaper-8-lcm', {
                device: 'webgpu',
            });
            log('DreamShaper loaded with WebGPU.');

            isReady = true;
            isInitializing = false;
            log('WebGPU Image Engine Ready.');
            if (window.onWebGpuImageReady) {
                window.onWebGpuImageReady(true);
            }
        } catch (e) {
            log('Init Error: ' + e.message);
            try {
                log('Falling back to WASM...');
                const { pipeline } = await import('https://cdn.jsdelivr.net/npm/@xenova/transformers@2.17.2/dist/transformers.min.js');
                pipe = await pipeline('text-to-image', 'Xenova/dreamshaper-8-lcm');
                isReady = true;
                isInitializing = false;
                log('WebGPU Image Engine Ready (WASM fallback).');
                if (window.onWebGpuImageReady) {
                    window.onWebGpuImageReady(true);
                }
            } catch (err) {
                isInitializing = false;
                log('Fatal Error: ' + err.message);
                if (window.onWebGpuImageError) {
                    window.onWebGpuImageError(err.message);
                }
            }
        }
    }

    window.generateWebGpuImage = async function(prompt, negativePrompt, steps) {
        if (!isReady) {
            log('Engine not ready');
            if (window.onWebGpuImageError) {
                window.onWebGpuImageError('Engine not ready');
            }
            return;
        }

        try {
            log('Generating: ' + prompt);

            const output = await pipe(prompt, {
                negative_prompt: negativePrompt || '',
                num_inference_steps: steps || 4,
                callback_on_step_end: (p, step_index, timestep, callback_kwargs) => {
                    if (window.onWebGpuImageProgress) {
                        window.onWebGpuImageProgress(step_index + 1, steps || 4);
                    }
                    if (window.onWebGpuImageProgressDart) {
                        window.onWebGpuImageProgressDart(step_index + 1, steps || 4);
                    }
                    return callback_kwargs;
                }
            });

            // Convert RawImage to Canvas
            const image = output.images[0];
            const canvas = document.createElement('canvas');
            canvas.width = image.width;
            canvas.height = image.height;
            const ctx = canvas.getContext('2d');

            const imgData = new ImageData(
                new Uint8ClampedArray(image.data),
                image.width,
                image.height
            );
            ctx.putImageData(imgData, 0, 0);

            const base64 = canvas.toDataURL('image/png');
            log('Generation complete: ' + image.width + 'x' + image.height);

            if (window.onWebGpuImageResult) {
                window.onWebGpuImageResult(base64);
            }
        } catch (e) {
            log('Generation Error: ' + e.message);
            if (window.onWebGpuImageError) {
                window.onWebGpuImageError(e.message);
            }
        }
    };

    window.initWebGpuImageEngine = function() {
        init();
    };

    window.webGpuImageEngine = {
        isReady: function() { return isReady; }
    };

    // Auto-init when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
