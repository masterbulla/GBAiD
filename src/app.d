import core.thread : Thread;

import std.stdio;
import std.getopt;
import std.string;
import std.file;
import std.path;

import derelict.sdl2.sdl;

import gbaid.util;
import gbaid.gba;
import gbaid.input;
import gbaid.audio;
import gbaid.render.renderer;

private enum string SAVE_EXTENSION = ".gsf";

public int main(string[] args) {
    // Parse comand line arguments
    string bios = null, save = null;
    bool noLoad = false, noSave = false;
    float scale = 2;
    bool fullScreen = false;
    FilteringMode filtering = FilteringMode.NONE;
    UpscalingMode upscaling = UpscalingMode.NONE;
    SaveConfiguration memory = SaveConfiguration.AUTO;
    bool controller = false;
    bool rtc = false;
    getopt(args,
        config.caseSensitive,
        "bios|b", &bios,
        "save|s", &save,
        config.bundling,
        "noload|n", &noLoad,
        "nosave|N", &noSave,
        config.noBundling,
        "scale|r", &scale,
        "fullscreen|R", &fullScreen,
        "filtering|f", &filtering,
        "upscaling|u", &upscaling,
        "memory|m", &memory,
        "controller|c", &controller,
        "rtc", &rtc
    );

    // Resolve BIOS
    if (bios is null) {
        writeln("Missing BIOS file path, sepcify with \"-b (path to bios)\"");
        return 1;
    }
    bios = expandPath(bios);
    if (!exists(bios)) {
        writeln("BIOS file doesn't exist");
        return 1;
    }

    // Resolve ROM
    string rom = args.getSafe!string(1, null);
    if (rom is null) {
        writeln("Missing ROM file path, sepcify as last argument");
        return 1;
    }
    rom = expandPath(rom);
    if (!exists(rom)) {
        writeln("ROM file doesn't exist");
        return 1;
    }

    // Resolve save
    if (save is null) {
        save = setExtension(rom, SAVE_EXTENSION);
        writeln("Save path not specified, using default \"", save, "\"");
    } else {
        save = expandPath(save);
    }
    bool newSave = void;
    if (noLoad) {
        newSave = true;
        writeln("Using new save");
    } else {
        if (exists(save)) {
            newSave = false;
            writeln("Found save \"", save, "\"");
        } else {
            newSave = true;
            writeln("Save file not found, using new save");
        }
    }

    // Create and configure GBA
    GameBoyAdvance gba = void;
    if (newSave) {
        gba = new GameBoyAdvance(bios, rom, memory);
    } else {
        gba = new GameBoyAdvance(bios, rom, save);
    }

    // Enable the Real Time clock if required
    if (rtc) {
        gba.enableRtc();
    }

    // Load and initialize SDL
    if (!DerelictSDL2.isLoaded) {
        DerelictSDL2.load();
    }
    SDL_Init(0);

    // Create the renderer, audio and input
    auto renderer = new FrameRenderer(DISPLAY_WIDTH, DISPLAY_HEIGHT);
    renderer.useVsync = true;
    renderer.fullScreen = fullScreen;
    renderer.setScale(scale);
    renderer.setFilteringMode(filtering);
    renderer.setUpscalingMode(upscaling);

    auto audio = new AudioQueue!2(SOUND_OUTPUT_FREQUENCY);
    gba.audioReceiver = &audio.queueAudio;

    auto keyboardInput = new Keyboard();
    InputSource auxiliaryInput = null;
    if (controller) {
        auxiliaryInput = new Controller();
    }

    renderer.create();
    audio.create();
    keyboardInput.create();
    if (auxiliaryInput !is null) {
        auxiliaryInput.create();
    }
    scope (exit) {
        keyboardInput.destroy();
        if (auxiliaryInput !is null) {
            auxiliaryInput.destroy();
        }
        audio.destroy();
        renderer.destroy();
        SDL_Quit();
    }

    // Declare a function for the GBA thread worker
    auto gbaRunning = true;
    void gbaRun() {
        while (gbaRunning) {
            scope (failure) {
                gbaRunning = false;
            }
            auto requiredSamples = audio.nextRequiredSamples();
            auto equivalentCycles = requiredSamples * CYCLES_PER_AUDIO_SAMPLE;
            gba.emulate(equivalentCycles);
        }
    }

    // Create the GBA worker
    auto gbaThread = new Thread(&gbaRun);
    gbaThread.name = "GBA";
    scope (failure) {
        gbaRunning = false;
    }

    // Start it
    gbaThread.start();
    audio.resume();

    // Update the input then draw the next frame, waiting for it if needed
    bool previousQuickSave = false;
    while (gbaRunning && !renderer.isCloseRequested()) {
        // Pass the keypad button state to the GBA
        keyboardInput.poll();
        auto keypadState = keyboardInput.keypadState;
        auto quickSave = keyboardInput.quickSave;
        if (auxiliaryInput !is null) {
            auxiliaryInput.poll();
            keypadState |= auxiliaryInput.keypadState;
            quickSave |= auxiliaryInput.quickSave;
        }
        gba.setKeypadState(keypadState);
        // Quick save if requested
        if (!previousQuickSave && quickSave) {
            if (noSave) {
                writeln("Saving is disabled");
            } else {
                audio.pause();
                gba.saveSave(save);
                writeln("Quick saved \"", save, "\"");
                audio.resume();
            }
        }
        previousQuickSave = quickSave;
        // Draw the lastest frame
        renderer.draw(gba.frameSwapper.nextFrame);
    }

    // Shutdown the worker
    gbaRunning = false;
    gbaThread.join();

    // Save Game Pak save
    if (noSave) {
        writeln("Saving is disabled");
    } else {
        gba.saveSave(save);
        writeln("Saved \"", save, "\"");
    }

    return 0;
}
