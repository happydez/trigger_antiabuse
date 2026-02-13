#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <convar_class>

#undef REQUIRE_PLUGIN
#include <shavit/core>

#define DEBUG 0

// Per-player teleport tracking
int gI_LastTeleportTick[MAXPLAYERS+1];
float gF_LastPosition[MAXPLAYERS+1][3];

Convar gCV_Enabled = null;
Convar gCV_GraceTicks = null;

DynamicHook gH_TeleportHook = null;

public Plugin myinfo =
{
    name = "Trigger Anti-Abuse",
    author = "happydez",
    description = "Prevents trigger_push and trigger_multiple velocity abuse via noclip/restore spam",
    version = "1.0.0",
    url = "https://github.com/happydez/trigger_antiabuse"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("TriggerAntiAbuse_MarkTeleport", Native_MarkTeleport);
    CreateNative("TriggerAntiAbuse_ClearTeleport", Native_ClearTeleport);

    RegPluginLibrary("trigger-antiabuse");

    return APLRes_Success;
}

public void OnPluginStart()
{
    gCV_Enabled = new Convar("trigger_antiabuse_enabled", "1", "Enable trigger anti-abuse protection", 0, true, 0.0, true, 1.0);
    gCV_GraceTicks = new Convar("trigger_antiabuse_grace", "8", "Ticks after teleport where trigger re-entry is blocked", 0, true, 1.0, true, 100.0);
    Convar.AutoExecConfig();

    GameData gd = new GameData("sdktools.games");
    if (gd != null)
    {
        int offset = gd.GetOffset("Teleport");
        if (offset != -1)
        {
            gH_TeleportHook = new DynamicHook(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
            gH_TeleportHook.AddParam(HookParamType_VectorPtr, .custom_register=DHookRegister_Default);
            gH_TeleportHook.AddParam(HookParamType_VectorPtr, .custom_register=DHookRegister_Default);
            gH_TeleportHook.AddParam(HookParamType_VectorPtr, .custom_register=DHookRegister_Default);
        }

        delete gd;
    }

    HookExistingTriggers();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
}

void HookExistingTriggers()
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "trigger_push")) != -1)
    {
        SDKHook(entity, SDKHook_StartTouch, OnTriggerStartTouch);
    }

    entity = -1;
    while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
    {
        SDKHook(entity, SDKHook_StartTouch, OnTriggerStartTouch);
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrEqual(classname, "trigger_push") || StrEqual(classname, "trigger_multiple"))
    {
        SDKHook(entity, SDKHook_SpawnPost, OnTriggerSpawnPost);
    }
}

void OnTriggerSpawnPost(int entity)
{
    if (IsValidEntity(entity))
    {
        SDKHook(entity, SDKHook_StartTouch, OnTriggerStartTouch);
    }
}

public void OnClientPutInServer(int client)
{
    gI_LastTeleportTick[client] = 0;
    gF_LastPosition[client][0] = 0.0;
    gF_LastPosition[client][1] = 0.0;
    gF_LastPosition[client][2] = 0.0;

    if (gH_TeleportHook != null)
    {
        gH_TeleportHook.HookEntity(Hook_Pre, client, OnPlayerTeleport);
    }
}

public void OnClientDisconnect(int client)
{
    gI_LastTeleportTick[client] = 0;
}

// Called when player is teleported via TeleportEntity
MRESReturn OnPlayerTeleport(int client, DHookParam hParams)
{
    if (client < 1 || client > MaxClients)
    {
        return MRES_Ignored;
    }

    if (!hParams.IsNull(1))
    {
        gI_LastTeleportTick[client] = GetGameTickCount();

        #if DEBUG
            PrintToChat(client, "[trigger-antiabuse] Teleport detected at tick %d", gI_LastTeleportTick[client]);
        #endif
    }

    return MRES_Ignored;
}

// detect large position changes
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!gCV_Enabled.BoolValue)
    {
        return Plugin_Continue;
    }

    if (!IsPlayerAlive(client))
    {
        return Plugin_Continue;
    }

    float currentPos[3];
    GetClientAbsOrigin(client, currentPos);
    float dist = GetVectorDistance(currentPos, gF_LastPosition[client]);
    if (dist > 200.0 && gF_LastPosition[client][0] != 0.0) // If moved more than 200 units in one tick, it's likely a teleport
    {
        gI_LastTeleportTick[client] = GetGameTickCount();

        #if DEBUG
            PrintToChat(client, "[trigger-antiabuse] Position jump detected (%.0f units)", dist);
        #endif
    }

    gF_LastPosition[client] = currentPos;

    return Plugin_Continue;
}

Action OnTriggerStartTouch(int entity, int other)
{
    if (!gCV_Enabled.BoolValue)
    {
        return Plugin_Continue;
    }

    if (other < 1 || other > MaxClients || !IsClientInGame(other))
    {
        return Plugin_Continue;
    }

    int currentTick = GetGameTickCount();
    int ticksSinceTeleport = currentTick - gI_LastTeleportTick[other];
    int graceTicks = gCV_GraceTicks.IntValue;
    if (ticksSinceTeleport >= 0 && ticksSinceTeleport < graceTicks) // If player was recently teleported, block trigger activation
    {
        #if DEBUG
            char classname[32];
            GetEntityClassname(entity, classname, sizeof(classname));
            PrintToChat(other, "[TAA] Blocked %s (teleport grace: %d/%d ticks)", classname, ticksSinceTeleport, graceTicks);
        #endif

        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public void Shavit_OnStart_Post(int client, int track)
{
    gI_LastTeleportTick[client] = 0;
}

public void Shavit_OnRestart_Post(int client, int track)
{
    gI_LastTeleportTick[client] = GetGameTickCount();
}

public int Native_MarkTeleport(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
    {
        return 0;
    }

    gI_LastTeleportTick[client] = GetGameTickCount();

    return 1;
}

public int Native_ClearTeleport(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
    {
        return 0;
    }

    gI_LastTeleportTick[client] = 0;

    return 1;
}
