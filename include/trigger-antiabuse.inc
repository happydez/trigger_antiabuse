#if defined _trigger_antiabuse_included
    #endinput
#endif
#define _trigger_antiabuse_included

/**
 * Marks that a client was just teleported.
 * Triggers will be blocked for the grace period.
 *
 * @param client    Client index.
 * @return          1 on success, 0 on failure.
 */
native int TriggerAntiAbuse_MarkTeleport(int client);

/**
 * Clears the teleport flag for a client.
 * Use this when teleport is legitimate (e.g., Timer Start).
 *
 * @param client    Client index.
 * @return          1 on success, 0 on failure.
 */
native int TriggerAntiAbuse_ClearTeleport(int client);

public SharedPlugin __pl_trigger_antiabuse =
{
    name = "trigger-antiabuse",
    file = "trigger-antiabuse.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_trigger_antiabuse_SetNTVOptional()
{
    MarkNativeAsOptional("TriggerAntiAbuse_MarkTeleport");
    MarkNativeAsOptional("TriggerAntiAbuse_ClearTeleport");
}
#endif
