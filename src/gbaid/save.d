module gbaid.save;

import std.format : format;
import std.typecons : tuple, Tuple;
import std.file : read, FileException;
import std.stdio : File;
import std.algorithm.comparison : min;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.digest.crc : CRC32;
import std.zlib : compress, uncompress;

import gbaid.gba.memory : GamePakData, MainSaveKind, EEPROM_SIZE, SRAM_SIZE, FLASH_512K_SIZE, FLASH_1M_SIZE, RTC_SIZE;

import gbaid.util;

public alias RawSaveMemory = Tuple!(SaveMemoryKind, void[]);

public enum SaveMemoryKind : int {
    EEPROM = 0,
    SRAM = 1,
    FLASH_512K = 2,
    FLASH_1M = 3,
    RTC = 4
}

private enum int SAVE_CURRENT_VERSION = 1;
private immutable char[8] SAVE_FORMAT_MAGIC = "GBAiDSav";

public enum int[SaveMemoryKind] memoryCapacityForSaveKind = [
    SaveMemoryKind.EEPROM: EEPROM_SIZE,
    SaveMemoryKind.SRAM: SRAM_SIZE,
    SaveMemoryKind.FLASH_512K: FLASH_512K_SIZE,
    SaveMemoryKind.FLASH_1M: FLASH_1M_SIZE,
    SaveMemoryKind.RTC: RTC_SIZE,
];

private enum string[][MainSaveKind] mainSaveKindIds = [
    MainSaveKind.SRAM: ["SRAM_V"],
    MainSaveKind.FLASH_512K: ["FLASH_V", "FLASH512_V"],
    MainSaveKind.FLASH_1M: ["FLASH1M_V"],
];

private enum string eepromSaveId = "EEPROM_V";

public enum MainSaveConfig : int {
    SRAM = MainSaveKind.SRAM,
    FLASH_512K = MainSaveKind.FLASH_512K,
    FLASH_1M = MainSaveKind.FLASH_1M,
    NONE = MainSaveKind.NONE,
    AUTO = -1
}

public enum EepromConfig {
    ON, OFF, AUTO
}

public enum RtcConfig {
    ON, OFF, AUTO
}

public GamePakData gamePakForNewRom(string romFile = null, MainSaveConfig mainSaveConfig = MainSaveConfig.AUTO,
        EepromConfig eepromConfig = EepromConfig.AUTO,
        RtcConfig rtcConfig = RtcConfig.AUTO) {
    return gamePakForRom(romFile, null, mainSaveConfig, eepromConfig, rtcConfig);
}

public GamePakData gamePakForExistingRom(string romFile, string saveFile,
        EepromConfig eepromConfig = EepromConfig.AUTO,
        RtcConfig rtcConfig = RtcConfig.AUTO) {
    return gamePakForRom(romFile, saveFile, MainSaveConfig.AUTO, eepromConfig, rtcConfig);
}

private GamePakData gamePakForRom(string romFile, string saveFile, MainSaveConfig mainSaveConfig,
        EepromConfig eepromConfig, RtcConfig rtcConfig) {
    GamePakData gamePakData;
    // Load the ROM if provided
    if (romFile !is null) {
        try {
            gamePakData.rom = romFile.read();
        } catch (FileException ex) {
            throw new Exception("Cannot read ROM file", ex);
        }
    }
    // Load the save file if provided, otherwise create the main save from the config
    if (saveFile !is null) {
        saveFile.loadSave(gamePakData);
    } else {
        final switch (mainSaveConfig) with (MainSaveConfig) {
            case SRAM:
            case FLASH_512K:
            case FLASH_1M:
            case NONE:
                gamePakData.mainSaveKind = cast(MainSaveKind) mainSaveConfig;
                break;
            case AUTO:
                gamePakData.mainSaveKind = gamePakData.rom.detectMainSaveKind();
                break;
        }
    }
    // Load the EEPROM
    final switch (eepromConfig) with (EepromConfig) {
        case ON:
            gamePakData.eepromEnabled = true;
            break;
        case OFF:
            gamePakData.eepromEnabled = false;
            break;
        case AUTO:
            if (saveFile is null) {
                gamePakData.eepromEnabled = gamePakData.rom.detectNeedEeprom();
            }
            break;
    }
    // Load the RTC
    final switch (rtcConfig) with (RtcConfig) {
        case ON:
            gamePakData.rtcEnabled = true;
            break;
        case OFF:
            gamePakData.rtcEnabled = false;
            break;
        case AUTO:
            if (saveFile is null) {
                gamePakData.rtcEnabled = gamePakData.rom.detectNeedRtc();
            }
            break;
    }
    return gamePakData;
}

private void loadSave(string saveFile, ref GamePakData gamePakData) {
    RawSaveMemory[] memories = saveFile.loadSaveFile();
    bool foundSave = false, foundEeprom = false, foundRtc = false;
    foreach (memory; memories) {
        switch (memory[0]) with (SaveMemoryKind) {
            case SRAM:
                checkSaveMissing(foundSave);
                gamePakData.mainSave = memory[1];
                gamePakData.mainSaveKind = MainSaveKind.SRAM;
                break;
            case FLASH_512K:
                checkSaveMissing(foundSave);
                gamePakData.mainSave = memory[1];
                gamePakData.mainSaveKind = MainSaveKind.FLASH_512K;
                break;
            case FLASH_1M:
                checkSaveMissing(foundSave);
                gamePakData.mainSave = memory[1];
                gamePakData.mainSaveKind = MainSaveKind.FLASH_1M;
                break;
            case EEPROM:
                checkSaveMissing(foundEeprom);
                gamePakData.eeprom = memory[1];
                gamePakData.eepromEnabled = true;
                break;
            case RTC:
                checkSaveMissing(foundRtc);
                gamePakData.rtc = memory[1];
                gamePakData.rtcEnabled = true;
                break;
            default:
                throw new Exception(format("Unsupported memory save type: %d", memory[0]));
        }
    }
    // The Classis NES series games only have an EEPROM, so this is can happen
    if (!foundSave) {
        gamePakData.mainSaveKind = MainSaveKind.NONE;
    }
}

private void checkSaveMissing(ref bool found) {
    if (found) {
        throw new Exception("Found more than one possible save memory in the save file");
    }
    found = true;
}

private MainSaveKind detectMainSaveKind(void[] rom) {
    auto romChars = cast(char[]) rom;
    // The Classic NES series game lie about having and SRAM and refuse to boot if you have one
    if (romChars.length >= 0xAC && romChars[0xAC] == 'F') {
        // If the 4 character game code starts with F, then it is a Classic NES series game
        return MainSaveKind.NONE;
    }
    // Search for the save IDs in the ROM
    foreach (saveKind, saveIds; mainSaveKindIds) {
        foreach (saveId; saveIds) {
            for (size_t i = 0; i < romChars.length; i += 4) {
                if (romChars[i .. min(i + saveId.length, $)] == saveId) {
                    return saveKind;
                }
            }
        }
    }
    // Most games that don't declare a save memory kind use an SRAM
    return MainSaveKind.SRAM;
}

private bool detectNeedEeprom(void[] rom) {
    auto romChars = cast(char[]) rom;
    for (size_t i = 0; i < romChars.length; i += 4) {
        if (romChars[i .. min(i + eepromSaveId.length, $)] == eepromSaveId) {
            return true;
        }
    }
    return false;
}

private bool detectNeedRtc(void[] rom) {
    auto romChars = cast(char[]) rom;
    if (romChars.length < 0xAC) {
        return false;
    }
    // Pokémon Ruby/Sapphire/Emerald and Botkai 1 and 2 use an RTC
    if (romChars[0xAC] == 'U') {
        // This is the Botkai code
        return true;
    }
    // For Pokémon we use the game title
    auto title = romChars[0xA0 .. 0xAC];
    return title == "POKEMON RUBY" || title == "POKEMON SAPP" || title == "POKEMON EMER";
}

public void saveGamePak(GamePakData gamePakData, string saveFile) {
    RawSaveMemory[] memories;
    final switch (gamePakData.mainSaveKind) with (MainSaveKind) {
        case SRAM:
            memories ~= tuple(SaveMemoryKind.SRAM, gamePakData.mainSave);
            break;
        case FLASH_512K:
            memories ~= tuple(SaveMemoryKind.FLASH_512K, gamePakData.mainSave);
            break;
        case FLASH_1M:
            memories ~= tuple(SaveMemoryKind.FLASH_1M, gamePakData.mainSave);
            break;
        case NONE:
            break;
    }
    if (gamePakData.eepromEnabled) {
        memories ~= tuple(SaveMemoryKind.EEPROM, gamePakData.eeprom);
    }
    if (gamePakData.rtcEnabled) {
        memories ~= tuple(SaveMemoryKind.RTC, gamePakData.rtc);
    }
    memories.saveSaveFile(saveFile);
}

/*
All ints are 32 bit and stored in little endian.
The CRCs are calculated on the little endian values

Format:
    Header:
        8 bytes: magic number (ASCII string of "GBAiDSav")
        1 int: version number
        1 int: option flags
        1 int: number of memory objects (n)
        1 int: CRC of the memory header (excludes magic number)
    Body:
        n memory blocks:
            1 int: memory kind ID, as per the SaveMemoryKind enum
            1 int: compressed memory size in bytes (c)
            c bytes: memory compressed with zlib
            1 int: CRC of the memory block
*/

public RawSaveMemory[] loadSaveFile(string filePath) {
    // Open the file in binary to read
    auto file = File(filePath, "rb");
    // Read the first 8 bytes to make sure it is a save file for GBAiD
    char[8] magicChars;
    file.rawRead(magicChars);
    if (magicChars != SAVE_FORMAT_MAGIC) {
        throw new Exception(format("Not a GBAiD save file (magic number isn't \"%s\" in ASCII)", SAVE_FORMAT_MAGIC));
    }
    // Read the version number
    auto versionNumber = file.readLittleEndianInt();
    // Use the proper reader for the version
    switch (versionNumber) {
        case 1:
            return file.readRawSaveMemories!1();
        default:
            throw new Exception(format("Unknown save file version: %d", versionNumber));
    }
}

private RawSaveMemory[] readRawSaveMemories(int versionNumber: 1)(File file) {
    CRC32 hash;
    hash.put([0x1, 0x0, 0x0, 0x0]);
    // Read the options flags, which are unused in this version
    auto optionFlags = file.readLittleEndianInt(&hash);
    // Read the number of save memories in the file
    auto memoryCount = file.readLittleEndianInt(&hash);
    // Read the header CRC checksum
    ubyte[4] headerCrc;
    file.rawRead(headerCrc);
    // Check the CRC
    if (hash.finish() != headerCrc) {
        throw new Exception("The save file has a corrupted header, the CRCs do not match");
    }
    // Read all the raw save memories according to the configurations given by the header
    RawSaveMemory[] saveMemories;
    foreach (i; 0 .. memoryCount) {
        saveMemories ~= file.readRawSaveMemory!versionNumber();
    }
    return saveMemories;
}

private RawSaveMemory readRawSaveMemory(int versionNumber: 1)(File file) {
    CRC32 hash;
    // Read the memory kind
    auto kindId = file.readLittleEndianInt(&hash);
    // Read the memory compressed size
    auto compressedSize = file.readLittleEndianInt(&hash);
    // Read the compressed bytes for the memory
    ubyte[] memoryCompressed;
    memoryCompressed.length = compressedSize;
    file.rawRead(memoryCompressed);
    hash.put(memoryCompressed);
    // Read the block CRC checksum
    ubyte[4] blockCrc;
    file.rawRead(blockCrc);
    // Check the CRC
    if (hash.finish() != blockCrc) {
        throw new Exception("The save file has a corrupted memory block, the CRCs do not match");
    }
    // Get the memory length according to the kind
    auto saveKind = cast(SaveMemoryKind) kindId;
    auto uncompressedSize = memoryCapacityForSaveKind[saveKind];
    // Uncompress the memory
    auto memoryUncompressed = memoryCompressed.uncompress(uncompressedSize);
    // Check that the uncompressed length matches the one for the kind
    if (memoryUncompressed.length != uncompressedSize) {
        throw new Exception(format("The uncompressed save memory has a different length than its kind: %d != %d",
                memoryUncompressed.length, uncompressedSize));
    }
    return tuple(saveKind, memoryUncompressed);
}

public void saveSaveFile(RawSaveMemory[] saveMemories, string filePath) {
    // Open the file in binary to write
    auto file = File(filePath, "wb");
    // First we write the magic
    file.rawWrite(SAVE_FORMAT_MAGIC);
    // Next we write the current version
    CRC32 hash;
    file.writeLittleEndianInt(SAVE_CURRENT_VERSION, &hash);
    // Next we write the option flags, which are empty since they are unused
    file.writeLittleEndianInt(0, &hash);
    // Next we write the number of memory blocks
    file.writeLittleEndianInt(cast(int) saveMemories.length, &hash);
    // Next we write the header CRC
    file.rawWrite(hash.finish());
    // Finally write the memory blocks
    foreach (saveMemory; saveMemories) {
        file.writeRawSaveMemory(saveMemory);
    }
}

private void writeRawSaveMemory(File file, RawSaveMemory saveMemory) {
    CRC32 hash;
    // Write the memory kind
    file.writeLittleEndianInt(saveMemory[0], &hash);
    // Compress the save memory
    auto memoryCompressed = saveMemory[1].compress();
    // Write the memory compressed size
    file.writeLittleEndianInt(cast(int) memoryCompressed.length, &hash);
    // Write the compressed bytes for the memory
    hash.put(memoryCompressed);
    file.rawWrite(memoryCompressed);
    // Write the block CRC
    file.rawWrite(hash.finish());
}

private int readLittleEndianInt(File file, CRC32* hash = null) {
    ubyte[4] numberBytes;
    file.rawRead(numberBytes);
    if (hash !is null) {
        hash.put(numberBytes);
    }
    return numberBytes.littleEndianToNative!int();
}

private void writeLittleEndianInt(File file, int i, CRC32* hash = null) {
    auto numberBytes = i.nativeToLittleEndian();
    if (hash !is null) {
        hash.put(numberBytes);
    }
    file.rawWrite(numberBytes);
}
