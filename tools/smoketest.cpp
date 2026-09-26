#include "steam_api_shim.h"
#include <windows.h>
#include <stdio.h>

typedef void *(*CreateInterfaceFn)(const char *, int *);

int main(void)
{
    freopen("Z:\\home\\steamos\\smoke.log", "w", stdout); setvbuf(stdout, NULL, _IONBF, 0);
    HMODULE m = LoadLibraryA("lsteamclient_a64.dll");
    printf("LoadLibrary: %p (err %lu)\n", m, GetLastError());
    if (!m) return 1;
    CreateInterfaceFn ci = (CreateInterfaceFn)GetProcAddress(m, "CreateInterface");
    ISteamClient *client = (ISteamClient *)ci("SteamClient021", NULL);
    printf("client: %p\n", client);
    if (!client) return 2;
    HSteamPipe pipe = SteamAPI_ISteamClient_CreateSteamPipe(client);
    HSteamUser user = SteamAPI_ISteamClient_ConnectToGlobalUser(client, pipe);
    printf("pipe %d user %d\n", pipe, user);
    if (!user) return 3;
    ISteamUser *su = SteamAPI_ISteamClient_GetISteamUser(client, user, pipe, "SteamUser023");
    ISteamUtils *ut = SteamAPI_ISteamClient_GetISteamUtils(client, pipe, "SteamUtils010");
    ISteamFriends *fr = SteamAPI_ISteamClient_GetISteamFriends(client, user, pipe, "SteamFriends017");
    printf("steamid %llu loggedon %d appid %u name '%s'\n",
           (unsigned long long)SteamAPI_ISteamUser_GetSteamID(su), SteamAPI_ISteamUser_BLoggedOn(su),
           SteamAPI_ISteamUtils_GetAppID(ut), SteamAPI_ISteamFriends_GetPersonaName(fr));
    SteamAPI_ISteamClient_ReleaseUser(client, pipe, user);
    SteamAPI_ISteamClient_BReleaseSteamPipe(client, pipe);
    return 0;
}
