#include <windows.h>
#include <stdio.h>
int main(int argc, char **argv)
{
    freopen("Z:\\home\\steamos\\loadtest.log", "w", stdout);
    for (int i = 1; i < argc; i++)
    {
        HMODULE m = LoadLibraryA(argv[i]);
        printf("%s -> %p err %lu\n", argv[i], m, m ? 0 : GetLastError());
    }
    return 0;
}
