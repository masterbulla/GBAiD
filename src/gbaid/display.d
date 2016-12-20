module gbaid.display;

import core.thread;
import core.sync.mutex;

import std.algorithm;

import gbaid.cycle;
import gbaid.fast_mem;
import gbaid.dma;
import gbaid.interrupt;
import gbaid.util;

version (D_InlineAsm_X86) version = UseASM;
version (D_InlineAsm_X86_64) version = UseASM;

public class Display {
    public static enum uint HORIZONTAL_RESOLUTION = 240;
    public static enum uint VERTICAL_RESOLUTION = 160;
    private static enum uint LAYER_COUNT = 6;
    private static enum uint FRAME_SIZE = HORIZONTAL_RESOLUTION * VERTICAL_RESOLUTION;
    private static enum short TRANSPARENT = cast(short) 0x8000;
    private static enum uint BLANKING_RESOLUTION = 68;
    private static enum uint VERTICAL_TIMING_RESOLUTION = VERTICAL_RESOLUTION + BLANKING_RESOLUTION;
    private CycleSharer4* cycleSharer;
    private IoRegisters* ioRegisters;
    private Palette* palette;
    private Vram* vram;
    private Oam* oam;
    private InterruptHandler interruptHandler;
    private DMAs dmas;
    private Thread thread;
    private bool running = false;
    private short[FRAME_SIZE] frame;
    private short[HORIZONTAL_RESOLUTION][LAYER_COUNT] lines;
    private int[2] internalAffineReferenceX;
    private int[2] internalAffineReferenceY;
    private Mutex frameLock;

    public this(CycleSharer4* cycleSharer, IoRegisters* ioRegisters, Palette* palette, Vram* vram, Oam* oam,
            InterruptHandler interruptHandler, DMAs dmas) {
        this.cycleSharer = cycleSharer;
        this.ioRegisters = ioRegisters;
        this.palette = palette;
        this.vram = vram;
        this.oam = oam;
        this.interruptHandler = interruptHandler;
        this.dmas = dmas;

        frameLock = new Mutex();

        ioRegisters.setPostWriteMonitor!0x28(&onAffineReferencePointPostWrite!(2, false));
        ioRegisters.setPostWriteMonitor!0x2C(&onAffineReferencePointPostWrite!(2, true));
        ioRegisters.setPostWriteMonitor!0x38(&onAffineReferencePointPostWrite!(3, false));
        ioRegisters.setPostWriteMonitor!0x3C(&onAffineReferencePointPostWrite!(3, true));
    }

    public void start() {
        if (thread is null) {
            thread = new Thread(&run);
            thread.name = "Display";
            running = true;
            thread.start();
        }
    }

    public void stop() {
        running = false;
        if (thread !is null) {
            thread.join(false);
            thread = null;
        }
    }

    public short[] lockFrame() {
        frameLock.lock();
        return frame;
    }

    public void unlockFrame() {
        frameLock.unlock();
    }

    private void reloadInternalAffineReferencePoint(int layer)() {
        enum affineLayer = layer - 2;
        int layerAddressOffset = affineLayer << 4;
        int dx = ioRegisters.getUnMonitored!int(0x28 + layerAddressOffset) << 4;
        internalAffineReferenceX[affineLayer] = dx >> 4;
        int dy = ioRegisters.getUnMonitored!int(0x2C + layerAddressOffset) << 4;
        internalAffineReferenceY[affineLayer] = dy >> 4;
    }

    private void onAffineReferencePointPostWrite(int layer, bool y)
            (IoRegisters* ioRegisters, int address, int shift, int mask, int oldValue, int newValue) {
        enum affineLayer = layer - 2;
        newValue <<= 4;
        newValue >>= 4;
        static if (y) {
            internalAffineReferenceY[affineLayer] = newValue;
        } else {
            internalAffineReferenceX[affineLayer] = newValue;
        }
    }

    private void run() {
        scope (exit) {
            cycleSharer.hasStopped!0();
        }
        while (running) {
            // Acquire the lock on the frame first
            frameLock.lock();
            foreach (line; 0 .. VERTICAL_TIMING_RESOLUTION) {
                // Draw visible lines now
                setHBLANK(line, false);
                if (line < VERTICAL_RESOLUTION) {
                    drawLine(line);
                }
                // Wait 4 cycles for each dot in the visible part of the line
                foreach (dot; 0 .. HORIZONTAL_RESOLUTION) {
                    cycleSharer.takeCycles!0(4);
                }
                // Update the control flags dependent on the line being drawn
                setVCOUNT(line);
                checkVMATCH(line);
                // Check if we are done drawing the frame
                if (line == VERTICAL_RESOLUTION - 1) {
                    // Release the lock on the frame
                    frameLock.unlock();
                    // We also need to reset the transformation data
                    reloadInternalAffineReferencePoint!2();
                    reloadInternalAffineReferencePoint!3();
                    // Finally we need to signal the end of the drawing
                    signalVBLANK();
                }
                // Wait 4 cycles for each dot in the blank part of the line
                setHBLANK(line, true);
                foreach (dot; 0 .. BLANKING_RESOLUTION) {
                    cycleSharer.takeCycles!0(4);
                }
            }
        }
    }

    private void drawLine(int line) {
        final switch (getMode()) with (Mode) {
            case TILED_TEXT:
                lineMode!"Text"(line);
                return;
            case TILED_MIXED:
                lineMode!"Mixed"(line);
                return;
            case TILED_AFFINE:
                lineMode!"Affine"(line);
                return;
            case BITMAP_16_SINGLE:
                lineMode!"Bitmap16Single"(line);
                return;
            case BITMAP_8_DOUBLE:
                lineMode!"Bitmap8Double"(line);
                return;
            case BITMAP_16_DOUBLE:
                lineMode!"Bitmap16Double"(line);
                return;
            case BLANK:
                lineBlank(line);
                return;
        }
    }

    private void lineMode(string type)(int line) {
        int displayControl = ioRegisters.getUnMonitored!short(0x0);
        int tileMapping = getBit(displayControl, 6);
        int bgEnables = getBits(displayControl, 8, 12);
        int windowEnables = getBits(displayControl, 13, 15);

        int blendControl = ioRegisters.getUnMonitored!short(0x50);

        short backColor = palette.get!short(0x0) & 0x7FFF;

        static if (type == "Text") {
            lineBackgroundText(line, lines[0], 0, bgEnables);
            lineBackgroundText(line, lines[1], 1, bgEnables);
            lineBackgroundText(line, lines[2], 2, bgEnables);
            lineBackgroundText(line, lines[3], 3, bgEnables);
        } else static if (type == "Mixed") {
            lineBackgroundText(line, lines[0], 0, bgEnables);
            lineBackgroundText(line, lines[1], 1, bgEnables);
            lineBackgroundAffine(line, lines[2], 2, bgEnables);
            lineTransparent(lines[3]);
        } else static if (type == "Affine") {
            lineTransparent(lines[0]);
            lineTransparent(lines[1]);
            lineBackgroundAffine(line, lines[2], 2, bgEnables);
            lineBackgroundAffine(line, lines[3], 3, bgEnables);
        } else {
            int frame = getBit(displayControl, 4);

            lineTransparent(lines[0]);
            lineTransparent(lines[1]);
            mixin ("lineBackground" ~ type ~ "(line, lines[2], bgEnables, frame);");
            lineTransparent(lines[3]);
        }

        lineObjects(line, lines[4], lines[5], bgEnables, tileMapping);
        lineCompose(line, windowEnables, blendControl, backColor);
    }

    private void lineBlank(int line) {
        uint p = line * HORIZONTAL_RESOLUTION;
        foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
            frame[p++] = cast(short) 0xFFFF;
        }
    }

    private void lineTransparent(short[] buffer) {
        foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
            buffer[column] = TRANSPARENT;
        }
    }

    private void lineBackgroundText(int line, short[] buffer, int layer, int bgEnables) {
        if (!checkBit(bgEnables, layer)) {
            foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
            }
            return;
        }

        int bgControlAddress = 0x8 + (layer << 1);
        int bgControl = ioRegisters.getUnMonitored!short(bgControlAddress);

        int tileBase = getBits(bgControl, 2, 3) << 14;
        int mosaic = getBit(bgControl, 6);
        int singlePalette = getBit(bgControl, 7);
        int mapBase = getBits(bgControl, 8, 12) << 11;
        int screenSize = getBits(bgControl, 14, 15);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int tile4Bit = singlePalette ? 0 : 1;
        int tileSizeShift = 6 - tile4Bit;

        int totalWidth = (256 << (screenSize & 0b1)) - 1;
        int totalHeight = (256 << ((screenSize & 0b10) >> 1)) - 1;

        int layerAddressOffset = layer << 2;
        int xOffset = ioRegisters.getUnMonitored!short(0x10 + layerAddressOffset) & 0x1FF;
        int yOffset = ioRegisters.getUnMonitored!short(0x12 + layerAddressOffset) & 0x1FF;

        int y = (line + yOffset) & totalHeight;

        if (y & ~255) {
            y &= 255;
            mapBase += BYTES_PER_KIB << (totalWidth & ~255 ? 2 : 1);
        }

        if (mosaic) {
            y -= y % mosaicSizeY;
        }

        int mapLine = y >> 3;
        int tileLine = y & 7;

        int lineMapOffset = mapLine << 5;

        version (UseASM) {
            size_t bufferAddress = cast(size_t) buffer.ptr;
            size_t vramAddress = cast(size_t) vram.getPointer!byte(0x0);
            size_t paletteAddress = cast(size_t) palette.getPointer!byte(0x0);

            enum string x64 =
                `asm {
                        push bufferAddress;
                        mov EAX, 0;
                        push RAX;
                    loop:
                        // calculate x for entire bg
                        add EAX, xOffset;
                        and EAX, totalWidth;
                        // start calculating tile address
                        mov EDX, mapBase;
                        // calculate x for section
                        test EAX, ~255;
                        jz skip_overflow;
                        and EAX, 255;
                        add EDX, 2048;
                    skip_overflow:
                        test mosaic, 1;
                        jz skip_mosaic;
                        // apply horizontal mosaic
                        push RDX;
                        xor EDX, EDX;
                        mov EBX, EAX;
                        mov ECX, mosaicSizeX;
                        div ECX;
                        sub EBX, EDX;
                        mov EAX, EBX;
                        pop RDX;
                    skip_mosaic:
                        // EAX = x, RDX = map
                        mov EBX, EAX;
                        // calculate tile map and column
                        shr EBX, 3;
                        and EAX, 7;
                        // calculate map address
                        add EBX, lineMapOffset;
                        shl EBX, 1;
                        add EDX, EBX;
                        add RDX, vramAddress;
                        // get tile
                        xor EBX, EBX;
                        mov BX, [RDX];
                        // EAX = tileColumn, EBX = tile
                        mov ECX, EAX;
                        // calculate sample column and line
                        test EBX, 0x400;
                        jz skip_hor_flip;
                        not ECX;
                        and ECX, 7;
                    skip_hor_flip:
                        mov EDX, tileLine;
                        test EBX, 0x800;
                        jz skip_ver_flip;
                        not EDX;
                        and EDX, 7;
                    skip_ver_flip:
                        // EBX = tile, ECX = sampleColumn, EDX = sampleLine
                        push RCX;
                        // calculate tile address
                        shl EDX, 3;
                        add EDX, ECX;
                        mov ECX, tile4Bit;
                        shr EDX, CL;
                        mov EAX, EBX;
                        and EAX, 0x3FF;
                        mov ECX, tileSizeShift;
                        shl EAX, CL;
                        add EAX, EDX;
                        add EAX, tileBase;
                        add RAX, vramAddress;
                        pop RCX;
                        // EAX = tileAddress, EBX = tile, ECX = sampleColumn
                        // calculate the palette address
                        mov DL, [RAX];
                        test singlePalette, 1;
                        jz mult_palettes;
                        and EDX, 0xFF;
                        jnz skip_transparent1;
                        mov CX, TRANSPARENT;
                        jmp end_color;
                    skip_transparent1:
                        shl EDX, 1;
                        jmp end_palettes;
                    mult_palettes:
                        and ECX, 1;
                        shl ECX, 2;
                        shr EDX, CL;
                        and EDX, 0xF;
                        jnz skip_transparent2;
                        mov CX, TRANSPARENT;
                        jmp end_color;
                    skip_transparent2:
                        shr EBX, 8;
                        and EBX, 0xF0;
                        add EDX, EBX;
                        shl EDX, 1;
                    end_palettes:
                        // EDX = paletteAddress
                        // get color from palette
                        add RDX, paletteAddress;
                        mov CX, [RDX];
                        and ECX, 0x7FFF;
                    end_color:
                        // ECX = color
                        pop RAX;
                        pop RBX;
                        // write color to line buffer
                        mov [RBX], CX;
                        // check loop condition
                        cmp EAX, 239;
                        jge end;
                        // increment address and counter
                        add RBX, 2;
                        push RBX;
                        add EAX, 1;
                        push RAX;
                        jmp loop;
                    end:
                        nop;
                }`;

            version (X86_64) mixin (x64);
            version (X86) mixin (x64_to_x86(x64));
        } else {
            foreach (column; 0 .. HORIZONTAL_RESOLUTION) {

                int x = (column + xOffset) & totalWidth;

                int map = mapBase;
                if (x & ~255) {
                    x &= 255;
                    map += BYTES_PER_KIB << 1;
                }

                if (mosaic) {
                    x -= x % mosaicSizeX;
                }

                int mapColumn = x >> 3;
                int tileColumn = x & 7;

                int mapAddress = map + (lineMapOffset + mapColumn << 1);

                int tile = vram.get!short(mapAddress);

                int tileNumber = tile & 0x3FF;

                int sampleColumn = void, sampleLine = void;
                if (tile & 0x400) {
                    sampleColumn = ~tileColumn & 7;
                } else {
                    sampleColumn = tileColumn;
                }
                if (tile & 0x800) {
                    sampleLine = ~tileLine & 7;
                } else {
                    sampleLine = tileLine;
                }

                int tileAddress = tileBase + (tileNumber << tileSizeShift) + ((sampleLine << 3) + sampleColumn >> tile4Bit);

                int paletteAddress = void;
                if (singlePalette) {
                    int paletteIndex = vram.get!byte(tileAddress) & 0xFF;
                    if (paletteIndex == 0) {
                        buffer[column] = TRANSPARENT;
                        continue;
                    }
                    paletteAddress = paletteIndex << 1;
                } else {
                    int paletteIndex = vram.get!byte(tileAddress) >> ((sampleColumn & 0b1) << 2) & 0xF;
                    if (paletteIndex == 0) {
                        buffer[column] = TRANSPARENT;
                        continue;
                    }
                    paletteAddress = (tile >> 8 & 0xF0) + paletteIndex << 1;
                }

                short color = palette.get!short(paletteAddress) & 0x7FFF;

                buffer[column] = color;
            }
        }
    }

    private void lineBackgroundAffine(int line, short[] buffer, int layer, int bgEnables) {
        if (!checkBit(bgEnables, layer)) {
            foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
            }

            int affineLayer = layer - 2;
            int layerAddressOffset = affineLayer << 4;
            int pb = ioRegisters.getUnMonitored!short(0x22 + layerAddressOffset);
            int pd = ioRegisters.getUnMonitored!short(0x26 + layerAddressOffset);

            internalAffineReferenceX[affineLayer] += pb;
            internalAffineReferenceY[affineLayer] += pd;
            return;
        }

        int bgControlAddress = 0x8 + (layer << 1);
        int bgControl = ioRegisters.getUnMonitored!short(bgControlAddress);

        int tileBase = getBits(bgControl, 2, 3) << 14;
        int mosaic = getBit(bgControl, 6);
        int mapBase = getBits(bgControl, 8, 12) << 11;
        int displayOverflow = getBit(bgControl, 13);
        int screenSize = getBits(bgControl, 14, 15);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int bgSize = (128 << screenSize) - 1;
        int bgSizeInv = ~bgSize;
        int mapLineShift = screenSize + 4;

        int affineLayer = layer - 2;
        int layerAddressOffset = affineLayer << 4;
        int pa = ioRegisters.getUnMonitored!short(0x20 + layerAddressOffset);
        int pb = ioRegisters.getUnMonitored!short(0x22 + layerAddressOffset);
        int pc = ioRegisters.getUnMonitored!short(0x24 + layerAddressOffset);
        int pd = ioRegisters.getUnMonitored!short(0x26 + layerAddressOffset);

        int dx = internalAffineReferenceX[affineLayer];
        int dy = internalAffineReferenceY[affineLayer];

        internalAffineReferenceX[affineLayer] += pb;
        internalAffineReferenceY[affineLayer] += pd;

        version (UseASM) {
            size_t bufferAddress = cast(size_t) buffer.ptr;
            size_t vramAddress = cast(size_t) vram.getPointer!byte(0x0);
            size_t paletteAddress = cast(size_t) palette.getPointer!byte(0x0);

            enum string x64 =
                `asm {
                        mov EAX, dx;
                        push RAX;
                        mov EBX, dy;
                        push RBX;
                        push bufferAddress;
                        push 0;
                    loop:
                        // calculate x
                        sar EAX, 8;
                        // calculate y
                        sar EBX, 8;
                        // EAX = x, EBX = y
                        // check and handle overflow
                        mov ECX, bgSizeInv;
                        test EAX, ECX;
                        jz skip_x_overflow;
                        test displayOverflow, 1;
                        jnz skip_transparent1;
                        mov CX, TRANSPARENT;
                        jmp end_color;
                    skip_transparent1:
                        and EAX, bgSize;
                    skip_x_overflow:
                        test EBX, ECX;
                        jz skip_y_overflow;
                        test displayOverflow, 1;
                        jnz skip_transparent2;
                        mov CX, TRANSPARENT;
                        jmp end_color;
                    skip_transparent2:
                        and EBX, bgSize;
                    skip_y_overflow:
                        // check and apply mosaic
                        test mosaic, 1;
                        jz skip_mosaic;
                        push RBX;
                        mov EBX, EAX;
                        xor EDX, EDX;
                        mov ECX, mosaicSizeX;
                        div ECX;
                        sub EBX, EDX;
                        pop RAX;
                        push RBX;
                        mov EBX, EAX;
                        xor EDX, EDX;
                        mov ECX, mosaicSizeY;
                        div ECX;
                        sub EBX, EDX;
                        pop RAX;
                    skip_mosaic:
                        // calculate the map address
                        push RAX;
                        push RBX;
                        shr EAX, 3;
                        shr EBX, 3;
                        mov ECX, mapLineShift;
                        shl EBX, CL;
                        add EAX, EBX;
                        add EAX, mapBase;
                        add RAX, vramAddress;
                        // get the tile number
                        xor ECX, ECX;
                        mov CL, [RAX];
                        // calculate the tile address
                        pop RBX;
                        pop RAX;
                        and EAX, 7;
                        and EBX, 7;
                        shl EBX, 3;
                        add EAX, EBX;
                        shl ECX, 6;
                        add EAX, ECX;
                        add EAX, tileBase;
                        add RAX, vramAddress;
                        // get the palette index
                        xor EDX, EDX;
                        mov DL, [RAX];
                        // calculate the palette address
                        shl EDX, 1;
                        jnz end_palettes;
                        mov CX, TRANSPARENT;
                        jmp end_color;
                    end_palettes:
                        // ECX = paletteAddress
                        // get color from palette
                        add RDX, paletteAddress;
                        mov CX, [RDX];
                        and ECX, 0x7FFF;
                    end_color:
                        // ECX = color
                        pop RAX;
                        pop RBX;
                        // EAX = index, EBX = buffer address
                        // write color to line buffer
                        mov [RBX], CX;
                        pop RDX;
                        pop RCX;
                        // ECX = dx, EDX = dy
                        // check loop condition
                        cmp EAX, 239;
                        jge end;
                        // increment dx and dy
                        add ECX, pa;
                        push RCX;
                        add EDX, pc;
                        push RDX;
                        // increment address and counter
                        add RBX, 2;
                        push RBX;
                        add EAX, 1;
                        push RAX;
                        // prepare for next iteration
                        mov EAX, ECX;
                        mov EBX, EDX;
                        jmp loop;
                    end:
                        nop;
                }`;

            version (X86_64) mixin (x64);
            version (X86) mixin (x64_to_x86(x64));
        } else {
            for (int column = 0; column < HORIZONTAL_RESOLUTION; column++, dx += pa, dy += pc) {
                int x = dx >> 8;
                int y = dy >> 8;

                if (x & bgSizeInv) {
                    if (displayOverflow) {
                        x &= bgSize;
                    } else {
                        buffer[column] = TRANSPARENT;
                        continue;
                    }
                }
                if (y & bgSizeInv) {
                    if (displayOverflow) {
                        y &= bgSize;
                    } else {
                        buffer[column] = TRANSPARENT;
                        continue;
                    }
                }

                if (mosaic) {
                    x -= x % mosaicSizeX;
                    y -= y % mosaicSizeY;
                }

                int mapColumn = x >> 3;
                int mapLine = y >> 3;

                int tileColumn = x & 7;
                int tileLine = y & 7;

                int mapAddress = mapBase + (mapLine << mapLineShift) + mapColumn;

                int tileNumber = vram.get!byte(mapAddress) & 0xFF;

                int tileAddress = tileBase + (tileNumber << 6) + (tileLine << 3) + tileColumn;

                int paletteAddress = (vram.get!byte(tileAddress) & 0xFF) << 1;

                if (paletteAddress == 0) {
                    buffer[column] = TRANSPARENT;
                    continue;
                }

                short color = palette.get!short(paletteAddress) & 0x7FFF;

                buffer[column] = color;
            }
        }
    }

    private void lineBackgroundBitmap16Single(int line, short[] buffer, int bgEnables, lazy int frame) {
        if (!checkBit(bgEnables, 2)) {
            foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
            }

            int pb = ioRegisters.getUnMonitored!short(0x22);
            int pd = ioRegisters.getUnMonitored!short(0x26);

            internalAffineReferenceX[0] += pb;
            internalAffineReferenceY[0] += pd;
            return;
        }

        int bgControl = ioRegisters.getUnMonitored!short(0xC);
        int mosaic = getBit(bgControl, 6);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int pa = ioRegisters.getUnMonitored!short(0x20);
        int pb = ioRegisters.getUnMonitored!short(0x22);
        int pc = ioRegisters.getUnMonitored!short(0x24);
        int pd = ioRegisters.getUnMonitored!short(0x26);

        int dx = internalAffineReferenceX[0];
        int dy = internalAffineReferenceY[0];

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++, dx += pa, dy += pc) {
            int x = dx >> 8;
            int y = dy >> 8;

            if (x < 0 || x >= HORIZONTAL_RESOLUTION || y < 0 || y >= VERTICAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
                continue;
            }

            if (mosaic) {
                x -= x % mosaicSizeX;
                y -= y % mosaicSizeY;
            }

            int address = x + y * HORIZONTAL_RESOLUTION << 1;

            short color = vram.get!short(address) & 0x7FFF;
            buffer[column] = color;
        }

        internalAffineReferenceX[0] += pb;
        internalAffineReferenceY[0] += pd;
    }

    private void lineBackgroundBitmap8Double(int line, short[] buffer, int bgEnables, int frame) {
        if (!checkBit(bgEnables, 2)) {
            foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
            }

            int pb = ioRegisters.getUnMonitored!short(0x22);
            int pd = ioRegisters.getUnMonitored!short(0x26);

            internalAffineReferenceX[0] += pb;
            internalAffineReferenceY[0] += pd;
            return;
        }

        int bgControl = ioRegisters.getUnMonitored!short(0xC);
        int mosaic = getBit(bgControl, 6);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int pa = ioRegisters.getUnMonitored!short(0x20);
        int pb = ioRegisters.getUnMonitored!short(0x22);
        int pc = ioRegisters.getUnMonitored!short(0x24);
        int pd = ioRegisters.getUnMonitored!short(0x26);

        int dx = internalAffineReferenceX[0];
        int dy = internalAffineReferenceY[0];

        int addressBase = frame ? 0xA000 : 0x0;

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++, dx += pa, dy += pc) {
            int x = dx >> 8;
            int y = dy >> 8;

            if (x < 0 || x >= HORIZONTAL_RESOLUTION || y < 0 || y >= VERTICAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
                continue;
            }

            if (mosaic) {
                x -= x % mosaicSizeX;
                y -= y % mosaicSizeY;
            }

            int address = x + y * HORIZONTAL_RESOLUTION + addressBase;

            int paletteIndex = vram.get!byte(address) & 0xFF;
            if (paletteIndex == 0) {
                buffer[column] = TRANSPARENT;
                continue;
            }
            int paletteAddress = paletteIndex << 1;

            short color = palette.get!short(paletteAddress) & 0x7FFF;
            buffer[column] = color;
        }

        internalAffineReferenceX[0] += pb;
        internalAffineReferenceY[0] += pd;
    }

    private void lineBackgroundBitmap16Double(int line, short[] buffer, int bgEnables, int frame) {
        if (!checkBit(bgEnables, 2)) {
            foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
                buffer[column] = TRANSPARENT;
            }

            int pb = ioRegisters.getUnMonitored!short(0x22);
            int pd = ioRegisters.getUnMonitored!short(0x26);

            internalAffineReferenceX[0] += pb;
            internalAffineReferenceY[0] += pd;
            return;
        }

        int bgControl = ioRegisters.getUnMonitored!short(0xC);
        int mosaic = getBit(bgControl, 6);

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        int pa = ioRegisters.getUnMonitored!short(0x20);
        int pb = ioRegisters.getUnMonitored!short(0x22);
        int pc = ioRegisters.getUnMonitored!short(0x24);
        int pd = ioRegisters.getUnMonitored!short(0x26);

        int dx = internalAffineReferenceX[0];
        int dy = internalAffineReferenceY[0];

        int addressBase = frame ? 0xA000 : 0x0;

        for (int column = 0; column < HORIZONTAL_RESOLUTION; column++, dx += pa, dy += pc) {
            int x = dx >> 8;
            int y = dy >> 8;

            if (x < 0 || x >= 160 || y < 0 || y >= 128) {
                buffer[column] = TRANSPARENT;
                continue;
            }

            if (mosaic) {
                x -= x % mosaicSizeX;
                y -= y % mosaicSizeY;
            }

            int address = x + y * 160 << 1;

            short color = vram.get!short(address) & 0x7FFF;
            buffer[column] = color;
        }

        internalAffineReferenceX[0] += pb;
        internalAffineReferenceY[0] += pd;
    }

    private void lineObjects(int line, short[] colorBuffer, short[] infoBuffer, int bgEnables, int tileMapping) {
        foreach (column; 0 .. HORIZONTAL_RESOLUTION) {
            colorBuffer[column] = TRANSPARENT;
            infoBuffer[column] = 3;
        }

        if (!checkBit(bgEnables, 4)) {
            return;
        }

        int tileBase = 0x10000;
        if (getMode() >= 3) {
            tileBase += 0x4000;
        }

        int mosaicControl = ioRegisters.getUnMonitored!int(0x4C);
        int mosaicSizeX = (mosaicControl & 0b1111) + 1;
        int mosaicSizeY = getBits(mosaicControl, 4, 7) + 1;

        foreach_reverse (i; 0 .. 128) {
            int attributeAddress = i << 3;

            int attribute0 = oam.get!short(attributeAddress);
            int rotAndScale = getBit(attribute0, 8);
            int doubleSize = getBit(attribute0, 9);

            if (!rotAndScale) {
                if (doubleSize) {
                    continue;
                }
            }

            int shape = getBits(attribute0, 14, 15);

            int attribute1 = oam.get!short(attributeAddress + 2);
            int size = getBits(attribute1, 14, 15);

            int y = attribute0 & 0xFF;
            if (y >= VERTICAL_RESOLUTION) {
                y -= 256;
            }

            int horizontalSize = void, verticalSize = void, mapYShift = void;
            if (shape == 0) {
                horizontalSize = 8 << size;
                verticalSize = horizontalSize;
                mapYShift = size;
            } else {
                int mapXShift = void;
                final switch (size) {
                    case 0:
                        horizontalSize = 16;
                        verticalSize = 8;
                        mapXShift = 0;
                        mapYShift = 1;
                        break;
                    case 1:
                        horizontalSize = 32;
                        verticalSize = 8;
                        mapXShift = 0;
                        mapYShift = 2;
                        break;
                    case 2:
                        horizontalSize = 32;
                        verticalSize = 16;
                        mapXShift = 1;
                        mapYShift = 2;
                        break;
                    case 3:
                        horizontalSize = 64;
                        verticalSize = 32;
                        mapXShift = 2;
                        mapYShift = 3;
                        break;
                }
                if (shape == 2) {
                    swap!int(horizontalSize, verticalSize);
                    swap!int(mapXShift, mapYShift);
                }
            }

            int sampleHorizontalSize = horizontalSize;
            int sampleVerticalSize = verticalSize;
            if (doubleSize) {
                horizontalSize <<= 1;
                verticalSize <<= 1;
            }

            int objectY = line - y;
            if (objectY < 0 || objectY >= verticalSize) {
                continue;
            }

            int horizontalSizeMask = void;
            int verticalSizeMask = void;
            if (rotAndScale) {
                horizontalSizeMask = ~(sampleHorizontalSize - 1);
                verticalSizeMask = ~(sampleVerticalSize - 1);
            } else {
                horizontalSizeMask = horizontalSize - 1;
                verticalSizeMask = verticalSize - 1;
            }

            int x = attribute1 & 0x1FF;
            if (x >= HORIZONTAL_RESOLUTION) {
                x -= 512;
            }

            int mode = getBits(attribute0, 10, 11);
            int mosaic = getBit(attribute0, 12);
            int singlePalette = getBit(attribute0, 13);

            int horizontalFlip = void, verticalFlip = void;
            int pa = void, pb = void, pc = void, pd = void;
            if (rotAndScale) {
                horizontalFlip = 0;
                verticalFlip = 0;
                int rotAndScaleParameters = getBits(attribute1, 9, 13);
                int parametersAddress = (rotAndScaleParameters << 5) + 0x6;
                pa = oam.get!short(parametersAddress);
                pb = oam.get!short(parametersAddress + 8);
                pc = oam.get!short(parametersAddress + 16);
                pd = oam.get!short(parametersAddress + 24);
            } else {
                horizontalFlip = getBit(attribute1, 12);
                verticalFlip = getBit(attribute1, 13);
                pa = 0;
                pb = 0;
                pc = 0;
                pd = 0;
            }

            int attribute2 = oam.get!short(attributeAddress + 4);
            int tileNumber = attribute2 & 0x3FF;
            int priority = getBits(attribute2, 10, 11);
            int paletteNumber = getBits(attribute2, 12, 15);

            foreach (objectX; 0 .. horizontalSize) {

                int column = objectX + x;

                if (column >= HORIZONTAL_RESOLUTION) {
                    continue;
                }

                int previousInfo = infoBuffer[column];

                int previousPriority = previousInfo & 0b11;
                if (priority > previousPriority) {
                    continue;
                }

                int sampleX = objectX, sampleY = objectY;

                if (rotAndScale) {
                    int tmpX = sampleX - (horizontalSize >> 1);
                    int tmpY = sampleY - (verticalSize >> 1);
                    sampleX = pa * tmpX + pb * tmpY >> 8;
                    sampleY = pc * tmpX + pd * tmpY >> 8;
                    sampleX += sampleHorizontalSize >> 1;
                    sampleY += sampleVerticalSize >> 1;
                    // this mask is inverted
                    if ((sampleX & horizontalSizeMask) || (sampleY & verticalSizeMask)) {
                        continue;
                    }
                } else {
                    if (horizontalFlip) {
                        sampleX = ~sampleX & horizontalSizeMask;
                    }
                    if (verticalFlip) {
                        sampleY = ~sampleY & verticalSizeMask;
                    }
                }

                if (mosaic) {
                    sampleX -= sampleX % mosaicSizeX;
                    sampleY -= sampleY % mosaicSizeY;
                }

                int mapX = sampleX >> 3;
                int mapY = sampleY >> 3;

                int tileX = sampleX & 7;
                int tileY = sampleY & 7;

                int tileAddress = tileNumber;

                if (tileMapping) {
                    // 1D
                    tileAddress += mapX + (mapY << mapYShift) << singlePalette;
                } else {
                    // 2D
                    tileAddress += (mapX << singlePalette) + (mapY << 5);
                }
                tileAddress <<= 5;

                tileAddress += tileX + (tileY << 3) >> (1 - singlePalette);

                tileAddress += tileBase;

                int paletteAddress = void;
                if (singlePalette) {
                    int paletteIndex = vram.get!byte(tileAddress) & 0xFF;
                    if (paletteIndex == 0) {
                        continue;
                    }
                    paletteAddress = paletteIndex << 1;
                } else {
                    int paletteIndex = vram.get!byte(tileAddress) >> ((tileX & 1) << 2) & 0xF;
                    if (paletteIndex == 0) {
                        continue;
                    }
                    paletteAddress = (paletteNumber << 4) + paletteIndex << 1;
                }

                short color = palette.get!short(0x200 + paletteAddress) & 0x7FFF;

                int modeFlags = mode << 2 | previousInfo & 0b1000;
                if (mode == 2) {
                    infoBuffer[column] = cast(short) (modeFlags | previousPriority);
                } else {
                    colorBuffer[column] = color;
                    infoBuffer[column] = cast(short) (modeFlags | priority);
                }
            }
        }
    }

    private void lineCompose(int line, int windowEnables, int blendControl, short backColor) {
        int colorEffect = getBits(blendControl, 6, 7);

        int[5] priorities = [
            ioRegisters.getUnMonitored!short(0x8) & 0b11,
            ioRegisters.getUnMonitored!short(0xA) & 0b11,
            ioRegisters.getUnMonitored!short(0xC) & 0b11,
            ioRegisters.getUnMonitored!short(0xE) & 0b11,
            0
        ];

        int[5] layerMap = [3, 2, 1, 0, 4];

        for (int column = 0, p = line * HORIZONTAL_RESOLUTION; column < HORIZONTAL_RESOLUTION; column++, p++) {

            int objInfo = lines[5][column];
            int objPriority = objInfo & 0b11;
            int objMode = objInfo >> 2;

            bool specialEffectEnabled = void;
            int layerEnables = void;

            int window = getWindow(windowEnables, objMode, line, column);
            if (window != 0) {
                int windowControl = ioRegisters.getUnMonitored!byte(window);
                layerEnables = windowControl & 0b11111;
                specialEffectEnabled = checkBit(windowControl, 5);
            } else {
                layerEnables = 0b11111;
                specialEffectEnabled = true;
            }

            priorities[4] = objPriority;

            short firstColor = backColor;
            short secondColor = backColor;

            int firstLayer = 5;
            int secondLayer = 5;

            int firstPriority = 3;
            int secondPriority = 3;

            foreach (int layer; layerMap) {

                if (!checkBit(layerEnables, layer)) {
                    continue;
                }

                short layerColor = lines[layer][column];

                if (layerColor & TRANSPARENT) {
                    continue;
                }

                int layerPriority = priorities[layer];

                if (layerPriority <= firstPriority) {

                    secondColor = firstColor;
                    secondLayer = firstLayer;
                    secondPriority = firstPriority;

                    firstColor = layerColor;
                    firstLayer = layer;
                    firstPriority = layerPriority;

                } else if (layerPriority <= secondPriority) {

                    secondColor = layerColor;
                    secondLayer = layer;
                    secondPriority = layerPriority;
                }
            }

            if (specialEffectEnabled) {
                if ((objMode & 0b1) && checkBit(blendControl, secondLayer + 8)) {
                    firstColor = applyBlendEffect(firstColor, secondColor);
                } else {
                    final switch (colorEffect) {
                        case 0:
                            break;
                        case 1:
                            if (checkBit(blendControl, firstLayer) && checkBit(blendControl, secondLayer + 8)) {
                                firstColor = applyBlendEffect(firstColor, secondColor);
                            }
                            break;
                        case 2:
                            if (checkBit(blendControl, firstLayer)) {
                                applyBrightnessIncreaseEffect(firstColor);
                            }
                            break;
                        case 3:
                            if (checkBit(blendControl, firstLayer)) {
                                applyBrightnessDecreaseEffect(firstColor);
                            }
                            break;
                    }
                }
            }

            frame[p] = firstColor;
        }
    }

    private int getWindow(int windowEnables, int objectMode, int line, int column) {
        if (!windowEnables) {
            return 0;
        }

        if (windowEnables & 0b1) {
            int horizontalDimensions = ioRegisters.getUnMonitored!short(0x40);

            int x1 = getBits(horizontalDimensions, 8, 15);
            int x2 = horizontalDimensions & 0xFF;

            int verticalDimensions = ioRegisters.getUnMonitored!short(0x44);

            int y1 = getBits(verticalDimensions, 8, 15);
            int y2 = verticalDimensions & 0xFF;

            if (column >= x1 && column < x2 && line >= y1 && line < y2) {
                return 0x48;
            }
        }

        if (windowEnables & 0b10) {
            int horizontalDimensions = ioRegisters.getUnMonitored!short(0x42);

            int x1 = getBits(horizontalDimensions, 8, 15);
            int x2 = horizontalDimensions & 0xFF;

            int verticalDimensions = ioRegisters.getUnMonitored!short(0x46);

            int y1 = getBits(verticalDimensions, 8, 15);
            int y2 = verticalDimensions & 0xFF;

            if (column >= x1 && column < x2 && line >= y1 && line < y2) {
                return 0x49;
            }
        }

        if (windowEnables & 0b100) {
            if (objectMode & 0b10) {
                return 0x4B;
            }
        }

        return 0x4A;
    }

    private void applyBrightnessIncreaseEffect(ref short first) {
        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int evy = min(ioRegisters.getUnMonitored!int(0x54) & 0b11111, 16);
        firstRed += (31 - firstRed) * evy + 8 >> 4;
        firstGreen += (31 - firstGreen) * evy + 8 >> 4;
        firstBlue += (31 - firstBlue) * evy + 8 >> 4;

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private void applyBrightnessDecreaseEffect(ref short first) {
        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int evy = min(ioRegisters.getUnMonitored!int(0x54) & 0b11111, 16);
        firstRed -= firstRed * evy + 8 >> 4;
        firstGreen -= firstGreen * evy + 8 >> 4;
        firstBlue -= firstBlue * evy + 8 >> 4;

        first = (firstBlue & 31) << 10 | (firstGreen & 31) << 5 | firstRed & 31;
    }

    private short applyBlendEffect(short first, short second) {
        int firstRed = first & 0b11111;
        int firstGreen = getBits(first, 5, 9);
        int firstBlue = getBits(first, 10, 14);

        int secondRed = second & 0b11111;
        int secondGreen = getBits(second, 5, 9);
        int secondBlue = getBits(second, 10, 14);

        int blendAlpha = ioRegisters.getUnMonitored!short(0x52);

        int eva = min(blendAlpha & 0b11111, 16);
        firstRed = firstRed * eva + 8 >> 4;
        firstGreen = firstGreen * eva + 8 >> 4;
        firstBlue = firstBlue * eva + 8 >> 4;

        int evb = min(getBits(blendAlpha, 8, 12), 16);
        secondRed = secondRed * evb + 8 >> 4;
        secondGreen = secondGreen * evb + 8 >> 4;
        secondBlue = secondBlue * evb + 8 >> 4;

        int blendRed = min(31, firstRed + secondRed);
        int blendGreen = min(31, firstGreen + secondGreen);
        int blendBlue = min(31, firstBlue + secondBlue);

        return (blendBlue & 31) << 10 | (blendGreen & 31) << 5 | blendRed & 31;
    }

    private Mode getMode() {
        int displayControl = ioRegisters.getUnMonitored!short(0x0);
        if (checkBit(displayControl, 7)) {
            return Mode.BLANK;
        }
        return cast(Mode) (displayControl & 0b111);
    }

    private void setHBLANK(int line, bool state) {
        int displayStatus = ioRegisters.getUnMonitored!short(0x4);
        setBit(displayStatus, 1, state);
        ioRegisters.setUnMonitored!short(0x4, cast(short) displayStatus);
        if (state) {
            if (line < VERTICAL_RESOLUTION) {
                dmas.signalHBLANK();
            }
            if (checkBit(displayStatus, 4)) {
                interruptHandler.requestInterrupt(InterruptSource.LCD_HBLANK);
            }
        }
    }

    private void setVCOUNT(int line) {
        ioRegisters.setUnMonitored!byte(0x6, cast(byte) line);
        int displayStatus = ioRegisters.getUnMonitored!short(0x4);
        setBit(displayStatus, 0, line >= VERTICAL_RESOLUTION && line < VERTICAL_TIMING_RESOLUTION - 1);
        setBit(displayStatus, 2, getBits(displayStatus, 8, 15) == line);
        ioRegisters.setUnMonitored!short(0x4, cast(short) displayStatus);
    }

    private void checkVMATCH(int line) {
        int displayStatus = ioRegisters.getUnMonitored!int(0x4);
        if (checkBit(displayStatus, 5) && getBits(displayStatus, 8, 15) == line) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_VCOUNTER_MATCH);
        }
    }

    private void signalVBLANK() {
        dmas.signalVBLANK();
        int displayStatus = ioRegisters.getUnMonitored!int(0x4);
        if (checkBit(displayStatus, 3)) {
            interruptHandler.requestInterrupt(InterruptSource.LCD_VBLANK);
        }
    }

    private static enum Mode {
        TILED_TEXT = 0,
        TILED_MIXED = 1,
        TILED_AFFINE = 2,
        BITMAP_16_SINGLE = 3,
        BITMAP_8_DOUBLE = 4,
        BITMAP_16_DOUBLE = 5,
        BLANK = 6
    }
}
