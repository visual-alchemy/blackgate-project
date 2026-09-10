#include <cstdio>
#include <cstring>

#include "DeckLinkAPI.h"

int main(int argc, char** argv)
{
    if (argc != 2 || std::strcmp(argv[1], "two-sub-devices-half") != 0) {
        std::fprintf(stderr, "usage: %s two-sub-devices-half\n", argv[0]);
        return 2;
    }

    IDeckLinkIterator* iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        std::fprintf(stderr, "DeckLink API unavailable\n");
        return 3;
    }

    IDeckLink* device = nullptr;
    int device_count = 0;
    int configured_count = 0;

    while (iterator->Next(&device) == S_OK) {
        IDeckLinkProfileManager* manager = nullptr;
        ++device_count;

        if (device->QueryInterface(IID_IDeckLinkProfileManager,
                                   reinterpret_cast<void**>(&manager)) == S_OK) {
            IDeckLinkProfile* profile = nullptr;
            HRESULT result = manager->GetProfile(
                bmdProfileTwoSubDevicesHalfDuplex, &profile);

            if (result == S_OK && profile) {
                bool active = false;
                profile->IsActive(&active);

                if (!active)
                    result = profile->SetActive();

                if (result == S_OK) {
                    ++configured_count;
                    std::printf("DeckLink device %d: 2dhd active\n", device_count - 1);
                } else {
                    std::fprintf(stderr,
                                 "DeckLink device %d: activation failed (0x%08x)\n",
                                 device_count - 1, static_cast<unsigned>(result));
                }

                profile->Release();
            }

            manager->Release();
        }

        device->Release();
    }

    iterator->Release();

    if (device_count == 0) {
        std::fprintf(stderr, "No DeckLink devices found\n");
        return 4;
    }

    if (configured_count == 0) {
        std::fprintf(stderr, "No device accepted 2dhd profile\n");
        return 5;
    }

    return 0;
}
