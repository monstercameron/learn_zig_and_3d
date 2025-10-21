const std = @import("std");
const wasapi = @import("wasapi.zig");
const windows = std.os.windows;
const audio_api = @import("../audio.zig");

const MAX_VOICES = 64;

const Voice = struct {
    sound: ?*const audio_api.Sound = null,
    playback_handle_id: u64 = 0,
    position_frames: f64 = 0,
    volume: f32 = 1.0,
    pitch: f32 = 1.0,
    speed: f32 = 1.0,
    looping: bool = false,
    paused: bool = true,
};

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,

    device_enumerator: *wasapi.IMMDeviceEnumerator,
    device: *wasapi.IMMDevice,
    audio_client: *wasapi.IAudioClient,
    render_client: *wasapi.IAudioRenderClient,

    mix_format: *wasapi.WAVEFORMATEX,
    buffer_size_frames: u32,

    // Threading and synchronization
    audio_thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    audio_event: windows.HANDLE,

    // Mixer state
    voices: [MAX_VOICES]Voice = [_]Voice{} ** MAX_VOICES,
    voice_mutex: std.Thread.Mutex = .{}, // To protect access to the voices array
    next_playback_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) !AudioEngine {
        var self: AudioEngine = undefined;
        self.allocator = allocator;

        // Create an event for event-driven buffering
        self.audio_event = windows.CreateEventA(null, 0, 0, null) orelse return error.CreateEventFailed;

        // Initialize COM
        var hr = wasapi.CoInitializeEx(null, 0x0); // COINIT_APARTMENTTHREADED
        if (hr != windows.S_OK) {
            std.debug.print("CoInitializeEx failed: {any}\n", .{hr});
            return error.ComInitializationFailed;
        }

        // Create Device Enumerator
        hr = wasapi.CoCreateInstance(&wasapi.CLSID_MMDeviceEnumerator, null, 0x1 | 0x2 | 0x4 | 0x10, &wasapi.IID_IMMDeviceEnumerator, @ptrCast(&self.device_enumerator));
        if (hr != windows.S_OK) {
            wasapi.CoUninitialize();
            return error.DeviceEnumeratorCreationFailed;
        }

        // Get Default Audio Endpoint
        hr = self.device_enumerator.getDefaultAudioEndpoint(0, 1, &self.device);
        if (hr != windows.S_OK) {
            _ = self.device_enumerator.release();
            wasapi.CoUninitialize();
            return error.GetDefaultAudioEndpointFailed;
        }

        // Activate IAudioClient
        hr = self.device.activate(&wasapi.IID_IAudioClient, @ptrCast(&self.audio_client));
        if (hr != windows.S_OK) {
            _ = self.device.release();
            _ = self.device_enumerator.release();
            wasapi.CoUninitialize();
            return error.AudioClientActivationFailed;
        }

        // Get the device's preferred audio format
        hr = self.audio_client.getMixFormat(&self.mix_format);
        if (hr != windows.S_OK) {
            _ = self.audio_client.release();
            _ = self.device.release();
            _ = self.device_enumerator.release();
            wasapi.CoUninitialize();
            return error.GetMixFormatFailed;
        }

        // Initialize the audio stream
        const AUDCLNT_SHAREMODE_SHARED = 0;
        const AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000;
        hr = self.audio_client.initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, self.mix_format);
        if (hr != windows.S_OK) {
            wasapi.CoTaskMemFree(self.mix_format);
            _ = self.audio_client.release();
            _ = self.device.release();
            _ = self.device_enumerator.release();
            wasapi.CoUninitialize();
            return error.AudioClientInitializationFailed;
        }

        // Set the event handle that will be signaled when the buffer is ready
        hr = self.audio_client.setEventHandle(self.audio_event);
        if (hr != windows.S_OK) {
            // Non-fatal, but we can't use event-driven mode
            std.debug.print("SetEventHandle failed. Event-driven audio may not work.", .{});
        }

        hr = self.audio_client.getBufferSize(&self.buffer_size_frames);
        if (hr != windows.S_OK) {
            // non-fatal, but good to know
            std.debug.print("GetBufferSize failed, continuing anyway.", .{});
            self.buffer_size_frames = 0; // a default
        }

        // Get the render client, which is what we use to write audio data
        hr = self.audio_client.getService(&wasapi.IID_IAudioRenderClient, @ptrCast(&self.render_client));
        if (hr != windows.S_OK) {
            wasapi.CoTaskMemFree(self.mix_format);
            _ = self.audio_client.release();
            _ = self.device.release();
            _ = self.device_enumerator.release();
            wasapi.CoUninitialize();
            return error.RenderClientGetServiceFailed;
        }

        return self;
    }

    pub fn deinit(self: *AudioEngine) void {
        self.stop_flag.store(true, .release);
        if (self.audio_thread) |thread| {
            // Signal the event one last time to unblock the thread so it can exit
            _ = windows.SetEvent(self.audio_event);
            thread.join();
        }

        wasapi.CoTaskMemFree(self.mix_format);
        _ = self.render_client.release();
        _ = self.audio_client.release();
        _ = self.device.release();
        _ = self.device_enumerator.release();
        _ = windows.CloseHandle(self.audio_event);
        wasapi.CoUninitialize();
    }

    pub fn loadWav(self: *AudioEngine, file_path: []const u8) !*audio_api.Sound {
        var file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var stream = std.io.bufferedReader(file.reader()).stream();
        var wav_file = try std.wave.File.openStream(stream, self.allocator);
        defer wav_file.deinit();

        if (wav_file.wfx.wFormatTag != std.wave.WAVE_FORMAT_PCM and wav_file.wfx.wFormatTag != std.wave.WAVE_FORMAT_IEEE_FLOAT) {
            return error.UnsupportedWavFormat;
        }

        const sound = try self.allocator.create(audio_api.Sound);
        sound.sample_rate = wav_file.wfx.nSamplesPerSec;
        sound.channels = wav_file.wfx.nChannels;

        const frame_count = wav_file.data_chunk_size / wav_file.wfx.nBlockAlign;
        sound.samples = try self.allocator.alloc(f32, frame_count * sound.channels);

        var frame_index: usize = 0;
        while (frame_index < frame_count) {
            // Note: This is a simplified sample conversion. A real implementation
            // would need to handle more formats and be more robust.
            switch (wav_file.wfx.wBitsPerSample) {
                8 => {
                    const sample = try wav_file.reader.readByte();
                    sound.samples[frame_index] = (@as(f32, @floatFromInt(sample)) - 128.0) / 128.0;
                },
                16 => {
                    const sample = try wav_file.reader.readInt(i16, .little);
                    sound.samples[frame_index] = @as(f32, @floatFromInt(sample)) / 32768.0;
                },
                32 => {
                     if (wav_file.wfx.wFormatTag == std.wave.WAVE_FORMAT_IEEE_FLOAT) {
                        sound.samples[frame_index] = try wav_file.reader.readFloat(f32, .little);
                     } else {
                        // 32-bit PCM
                        const sample = try wav_file.reader.readInt(i32, .little);
                        sound.samples[frame_index] = @as(f32, @floatFromInt(sample)) / 2147483648.0;
                     }
                },
                else => return error.UnsupportedBitDepth,
            }
            frame_index += 1;
        }

        return sound;
    }

    pub fn unload(self: *AudioEngine, sound: *audio_api.Sound) void {
        self.allocator.free(sound.samples);
        self.allocator.destroy(sound);
    }

    pub fn start(self: *AudioEngine) !void {
        if (self.audio_thread != null) return; // Already started

        self.audio_thread = try std.Thread.spawn(.{}, audioThread, .{self});
        var hr = self.audio_client.start();
        if (hr != windows.S_OK) {
            return error.AudioClientStartFailed;
        }
    }

    fn audioThread(self: *AudioEngine) void {
        // This thread's main loop. It waits for a signal from the audio device,
        // then wakes up to provide more audio data.
        while (!self.stop_flag.load(.acquire)) {
            const wait_result = windows.WaitForSingleObject(self.audio_event, 1000); // 1 second timeout
            if (wait_result == windows.WAIT_OBJECT_0) {
                // Event was signaled, buffer needs data
                self.fillBuffer() catch |err| {
                    std.debug.print("fillBuffer failed: {any}\n", .{err});
                };
            }
        }
    }

    fn fillBuffer(self: *AudioEngine) !void {
        var hr: windows.HRESULT = undefined;

        var padding_frames: u32 = 0;
        hr = self.audio_client.getCurrentPadding(&padding_frames);
        if (hr != windows.S_OK) return error.GetCurrentPaddingFailed;

        const frames_to_write = self.buffer_size_frames - padding_frames;
        if (frames_to_write == 0) return;

        var buffer_ptr: ?*u8 = null;
        hr = self.render_client.getBuffer(frames_to_write, &buffer_ptr);
        if (hr != windows.S_OK) return error.GetBufferFailed;

        const buffer = @as([*]f32, @ptrCast(@alignCast(buffer_ptr.?)))[0 .. frames_to_write * self.mix_format.nChannels];
        @memset(buffer, 0.0); // Clear the buffer to start with silence

        self.voice_mutex.lock();
        defer self.voice_mutex.unlock();

        // --- Mixer Loop ---
        for (self.voices) |*voice| {
            if (voice.paused or voice.sound == null) continue;

            const sound_data = voice.sound.?;
            const samples = sound_data.samples;
            const num_channels = self.mix_format.nChannels;

            var i: u32 = 0;
            while (i < frames_to_write) : (i += 1) {
                const playback_speed = voice.speed * voice.pitch;
                const current_pos = voice.position_frames;
                const next_pos = voice.position_frames + playback_speed;

                // Simple linear interpolation for resampling
                const sample_index_a = @as(usize, @intFromFloat(@floor(current_pos)));
                const sample_index_b = sample_index_a + 1;
                const lerp_factor = @as(f32, @floatFromFloat(current_pos - @floor(current_pos)));

                if (sample_index_b >= sound_data.frameCount()) {
                    if (voice.looping) {
                        voice.position_frames = 0;
                    } else {
                        // Sound finished, mark for cleanup
                        voice.sound = null;
                        break;
                    }
                }

                // Mix each channel
                var channel: u16 = 0;
                while (channel < num_channels) : (channel += 1) {
                    const sample_a = samples[sample_index_a * num_channels + channel];
                    const sample_b = samples[sample_index_b * num_channels + channel];
                    const mixed_sample = sample_a + (sample_b - sample_a) * lerp_factor;
                    
                    buffer[i * num_channels + channel] += mixed_sample * voice.volume;
                }

                voice.position_frames = next_pos;
            }
        }

        hr = self.render_client.releaseBuffer(frames_to_write, 0);
        if (hr != windows.S_OK) return error.ReleaseBufferFailed;
    }
};
