#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <convar_class>

#undef REQUIRE_PLUGIN
#include <shavit/core>
#include <shavit/checkpoints>

#define DEBUG 0

// Per-player teleport tracking
int gI_LastTeleportTick[MAXPLAYERS+1];
float gF_LastPosition[MAXPLAYERS+1][3];

float gF_MaxAllowedSpeed[MAXPLAYERS+1];
float gF_PreFrameVelocity[MAXPLAYERS+1][3];

Convar gCV_Enabled = null;
Convar gCV_GraceTicks = null;
Convar gCV_VelocityDelta = null;
Convar gCV_SpeedBuffer = null;

DynamicHook gH_TeleportHook = null;

public Plugin myinfo =
{
    name = "Trigger Anti-Abuse",
    author = "happydez",
    description = "Prevents trigger_push and trigger_multiple velocity abuse via noclip/restore spam",
    version = "2.0.0",
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
    gCV_GraceTicks = new Convar("trigger_antiabuse_grace", "8", "Ticks after teleport where velocity is monitored", 0, true, 1.0, true, 100.0);
    gCV_VelocityDelta = new Convar("trigger_antiabuse_delta", "300.0", "Threshold for suspicious velocity increase per tick", 0, true, 100.0, true, 1000.0);
    gCV_SpeedBuffer = new Convar("trigger_antiabuse_buffer", "350.0", "Natural movement buffer added to max allowed speed", 0, true, 0.0, true, 1000.0);
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

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
        }
    }
}

public void OnClientPutInServer(int client)
{
    gI_LastTeleportTick[client] = 0;
    gF_LastPosition[client][0] = 0.0;
    gF_LastPosition[client][1] = 0.0;
    gF_LastPosition[client][2] = 0.0;
    gF_PreFrameVelocity[client][0] = 0.0;
    gF_PreFrameVelocity[client][1] = 0.0;
    gF_PreFrameVelocity[client][2] = 0.0;
    gF_MaxAllowedSpeed[client] = 0.0;

    if (gH_TeleportHook != null)
    {
        gH_TeleportHook.HookEntity(Hook_Pre, client, OnPlayerTeleport);
    }
}

public void OnClientDisconnect(int client)
{
    gI_LastTeleportTick[client] = 0;
    gF_MaxAllowedSpeed[client] = 0.0;
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
        MarkTeleport(client);
    }

    return MRES_Ignored;
}

void MarkTeleport(int client)
{
    gI_LastTeleportTick[client] = GetGameTickCount();

    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    gF_MaxAllowedSpeed[client] = GetHorizontalSpeed(vel) + gCV_SpeedBuffer.FloatValue;

    #if DEBUG
        PrintToChat(client, "[trigger-antiabuse] Teleport detected at tick %d, max speed: %.0f", gI_LastTeleportTick[client], gF_MaxAllowedSpeed[client]);
    #endif
}

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

    GetEntPropVector(client, Prop_Data, "m_vecVelocity", gF_PreFrameVelocity[client]);

    // Detect large position changes
    float currentPos[3];
    GetClientAbsOrigin(client, currentPos);
    float dist = GetVectorDistance(currentPos, gF_LastPosition[client]);
    if ((dist > 200.0) && (gF_LastPosition[client][0] != 0.0))
    {
        MarkTeleport(client);

        #if DEBUG
            PrintToChat(client, "[trigger-antiabuse] Position jump detected (%.0f units)", dist);
        #endif
    }

    gF_LastPosition[client] = currentPos;

    return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (!gCV_Enabled.BoolValue)
    {
        return;
    }

    if (!IsPlayerAlive(client))
    {
        return;
    }

    int currentTick = GetGameTickCount();
    int ticksSinceTeleport = currentTick - gI_LastTeleportTick[client];
    int graceTicks = gCV_GraceTicks.IntValue;
    if ((ticksSinceTeleport < 0) || (ticksSinceTeleport >= graceTicks))
    {
        return;
    }

    float currentVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", currentVel);

    float currentSpeed = GetHorizontalSpeed(currentVel);
    float preSpeed = GetHorizontalSpeed(gF_PreFrameVelocity[client]);
    float delta = currentSpeed - preSpeed;

    float maxDelta = gCV_VelocityDelta.FloatValue;
    float maxAllowed = gF_MaxAllowedSpeed[client];

    if ((delta > maxDelta) && (currentSpeed > maxAllowed))
    {
        #if DEBUG
            PrintToChat(client, "[trigger-antiabuse] Clamping velocity: %.0f -> %.0f (delta: %.0f, max: %.0f)", currentSpeed, maxAllowed, delta, maxAllowed);
        #endif

        if (currentSpeed > 0.0)
        {
            float scale = maxAllowed / currentSpeed;
            currentVel[0] *= scale;
            currentVel[1] *= scale;
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, currentVel);
        }
    }
    else if (delta < 0.0)
    {
        gF_MaxAllowedSpeed[client] = currentSpeed + gCV_SpeedBuffer.FloatValue;
    }
}

public void Shavit_OnStart_Post(int client, int track)
{
    gI_LastTeleportTick[client] = 0;
    gF_MaxAllowedSpeed[client] = 0.0;
}

public void Shavit_OnRestart_Post(int client, int track)
{
    MarkTeleport(client);
}

public Action Shavit_OnTeleport(int client, int index, int target)
{
    MarkTeleport(client);

    return Plugin_Continue;
}

public void Shavit_OnCheckpointCacheLoaded(int client, cp_cache_t cache, int index)
{
    MarkTeleport(client);
}

public int Native_MarkTeleport(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
    {
        return 0;
    }

    MarkTeleport(client);

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
    gF_MaxAllowedSpeed[client] = 0.0;

    return 1;
}

float GetHorizontalSpeed(float vel[3])
{
    return SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
}
