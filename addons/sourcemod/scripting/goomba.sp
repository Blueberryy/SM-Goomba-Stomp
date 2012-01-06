#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#undef REQUIRE_PLUGIN
#include <updater>

#define UPDATE_URL    "https://github.com/Flyflo/SM-Goomba-Stomp/raw/master/update.txt"

#define PL_NAME "Goomba Stomp Core"
#define PL_DESC "Goomba Stomp core plugin"
#define PL_VERSION "1.2.2"

#define STOMP_SOUND "goomba/stomp.wav"
#define REBOUND_SOUND "goomba/rebound.wav"

public Plugin:myinfo =
{
    name = PL_NAME,
    author = "Flyflo",
    description = PL_DESC,
    version = PL_VERSION,
    url = "http://www.geek-gaming.fr"
}

new Handle:g_hForwardOnPreStomp;

new Handle:g_Cvar_JumpPower = INVALID_HANDLE;
new Handle:g_Cvar_PluginEnabled = INVALID_HANDLE;
new Handle:g_Cvar_ParticlesEnabled = INVALID_HANDLE;
new Handle:g_Cvar_SoundsEnabled = INVALID_HANDLE;
new Handle:g_Cvar_ImmunityEnabled = INVALID_HANDLE;

new Handle:g_Cvar_DamageLifeMultiplier = INVALID_HANDLE;
new Handle:g_Cvar_DamageAdd = INVALID_HANDLE;

// Snippet from psychonic (http://forums.alliedmods.net/showpost.php?p=1294224&postcount=2)
new Handle:sv_tags;

new Handle:g_Cookie_ClientPref;

new Goomba_Fakekill[MAXPLAYERS+1];

// Thx to Pawn 3-pg (https://forums.alliedmods.net/showthread.php?p=1140480#post1140480)
new bool:g_TeleportAtFrameEnd[MAXPLAYERS+1] = false;
new Float:g_TeleportAtFrameEnd_Vel[MAXPLAYERS+1][3];

public APLRes:AskPluginLoad2(Handle:hMySelf, bool:bLate, String:strError[], iMaxErrors)
{
    CreateNative("GoombaStomp", GoombaStomp);
    CreateNative("CheckImmunity", CheckImmunity);
    CreateNative("PlayStompSound", PlayStompSound);
    CreateNative("PlayReboundSound", PlayReboundSound);

    return APLRes_Success;
}

public OnPluginStart()
{
    LoadTranslations("goomba.phrases");
    RegPluginLibrary("goomba");

    if (LibraryExists("updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }

    g_Cvar_PluginEnabled = CreateConVar("goomba_enabled", "1.0", "Plugin On/Off", 0, true, 0.0, true, 1.0);

    g_Cvar_SoundsEnabled = CreateConVar("goomba_sounds", "1", "Enable or disable sounds of the plugin", 0, true, 0.0, true, 1.0);
    g_Cvar_ParticlesEnabled = CreateConVar("goomba_particles", "1", "Enable or disable particles of the plugin", 0, true, 0.0, true, 1.0);
    g_Cvar_ImmunityEnabled = CreateConVar("goomba_immunity", "1", "Enable or disable the immunity system", 0, true, 0.0, true, 1.0);
    g_Cvar_JumpPower = CreateConVar("goomba_rebound_power", "300.0", "Goomba jump power", 0, true, 0.0);

    g_Cvar_DamageLifeMultiplier = CreateConVar("goomba_dmg_lifemultiplier", "1.0", "How much damage the victim will receive based on its actual life", 0, true, 0.0, false, 0.0);
    g_Cvar_DamageAdd = CreateConVar("goomba_dmg_add", "50.0", "Add this amount of damage after goomba_dmg_lifemultiplier calculation", 0, true, 0.0, false, 0.0);

    AutoExecConfig(true, "goomba");

    CreateConVar("goomba_version", PL_VERSION, PL_NAME, FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_Cookie_ClientPref = RegClientCookie("goomba_client_pref", "", CookieAccess_Private);
    RegConsoleCmd("goomba_toggle", Cmd_GoombaToggle, "Toggle the goomba immunity client's pref.");
    RegConsoleCmd("goomba_status", Cmd_GoombaStatus, "Give the current goomba immunity setting.");
    RegConsoleCmd("goomba_on", Cmd_GoombaOn, "Enable stomp.");
    RegConsoleCmd("goomba_off", Cmd_GoombaOff, "Disable stomp.");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("player_spawn", Event_PlayerSpawn);

    g_hForwardOnPreStomp = CreateGlobalForward("OnPreStomp", ET_Event, Param_Cell, Param_Cell, Param_FloatByRef, Param_FloatByRef, Param_FloatByRef);

    // sv_tags stuff
    sv_tags = FindConVar("sv_tags");
    MyAddServerTag("stomp");
    HookConVarChange(g_Cvar_PluginEnabled, OnPluginChangeState);

    // Support for plugin late loading
    for (new client = 1; client <= MaxClients; client++)
    {
        if(IsClientInGame(client))
        {
            OnClientPutInServer(client);
        }
    }
}

public OnPluginEnd()
{
    MyRemoveServerTag("stomp");
}

public OnMapStart()
{
    PrecacheSound(STOMP_SOUND, true);
    PrecacheSound(REBOUND_SOUND, true);

    decl String:stompSoundServerPath[128];
    decl String:reboundSoundServerPath[128];
    Format(stompSoundServerPath, sizeof(stompSoundServerPath), "sound/%s", STOMP_SOUND);
    Format(reboundSoundServerPath, sizeof(reboundSoundServerPath), "sound/%s", REBOUND_SOUND);

    AddFileToDownloadsTable(stompSoundServerPath);
    AddFileToDownloadsTable(reboundSoundServerPath);
}

public OnLibraryAdded(const String:name[])
{
    if (StrEqual(name, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }
}

public OnPluginChangeState(Handle:cvar, const String:oldVal[], const String:newVal[])
{
    if(GetConVarBool(g_Cvar_PluginEnabled))
    {
        MyAddServerTag("stomp");
    }
    else
    {
        MyRemoveServerTag("stomp");
    }
}

public OnClientPutInServer(client)
{
    SDKHook(client, SDKHook_PreThinkPost, OnPreThinkPost);
}

public CheckImmunity(Handle:hPlugin, numParams)
{
    if(numParams != 2)
    {
        return 3;
    }

    new client = GetNativeCell(1);
    new victim = GetNativeCell(2);

    if(GetConVarBool(g_Cvar_ImmunityEnabled))
    {
        decl String:strCookieClient[16];
        GetClientCookie(client, g_Cookie_ClientPref, strCookieClient, sizeof(strCookieClient));

        decl String:strCookieVictim[16];
        GetClientCookie(victim, g_Cookie_ClientPref, strCookieVictim, sizeof(strCookieVictim));

        if(StrEqual(strCookieClient, "on") || StrEqual(strCookieClient, "next_off"))
        {
            return 1;
        }
        else
        {
            if(StrEqual(strCookieVictim, "on") || StrEqual(strCookieVictim, "next_off"))
            {
                return 2;
            }
        }
    }

    return 0;
}


public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
    new victim = GetClientOfUserId(GetEventInt(event, "userid"));

    if(Goomba_Fakekill[victim] == 1)
    {
        SetEventBool(event, "goomba", true);
    }

    return Plugin_Continue;
}


public GoombaStomp(Handle:hPlugin, numParams)
{
    // If the plugin is disabled stop here
    if(!GetConVarBool(g_Cvar_PluginEnabled))
    {
        return false;
    }
    if(numParams < 2 || numParams > 5)
    {
        return false;
    }

    // Retrieve the parameters
    new client = GetNativeCell(1);
    new victim = GetNativeCell(2);

    new Float:damageMultiplier = GetConVarFloat(g_Cvar_DamageLifeMultiplier);
    new Float:damageBonus = GetConVarFloat(g_Cvar_DamageAdd);
    new Float:jumpPower = GetConVarFloat(g_Cvar_JumpPower);

    switch(numParams)
    {
        case 3:
            damageMultiplier = GetNativeCellRef(3);
        case 4:
            damageBonus = GetNativeCellRef(4);
        case 5:
            jumpPower = GetNativeCellRef(5);
    }

    new Float:modifiedDamageMultiplier = damageMultiplier;
    new Float:modifiedDamageBonus = damageBonus;
    new Float:modifiedJumpPower = jumpPower;

    // Launch forward
    decl Action:preStompForwardResult;

    Call_StartForward(g_hForwardOnPreStomp);
    Call_PushCell(client);
    Call_PushCell(victim);
    Call_PushFloatRef(modifiedDamageMultiplier);
    Call_PushFloatRef(modifiedDamageBonus);
    Call_PushFloatRef(modifiedJumpPower);
    Call_Finish(preStompForwardResult);

    if(preStompForwardResult == Plugin_Changed)
    {
        damageMultiplier = modifiedDamageMultiplier;
        damageBonus = modifiedDamageBonus;
        jumpPower = modifiedJumpPower;
    }
    else if(preStompForwardResult != Plugin_Continue)
    {
        return false;
    }

    if(GetConVarBool(g_Cvar_ParticlesEnabled))
    {
        new particle = AttachParticle(victim, "mini_fireworks");
        if(particle != -1)
        {
            CreateTimer(5.0, Timer_DeleteParticle, EntIndexToEntRef(particle), TIMER_FLAG_NO_MAPCHANGE);
        }
    }

    if(jumpPower > 0.0)
    {
        decl Float:vecAng[3], Float:vecVel[3];
        GetClientEyeAngles(client, vecAng);
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", vecVel);
        vecAng[0] = DegToRad(vecAng[0]);
        vecAng[1] = DegToRad(vecAng[1]);
        vecVel[0] = jumpPower * Cosine(vecAng[0]) * Cosine(vecAng[1]);
        vecVel[1] = jumpPower * Cosine(vecAng[0]) * Sine(vecAng[1]);
        vecVel[2] = jumpPower + 100.0;

        g_TeleportAtFrameEnd[client] = true;
        g_TeleportAtFrameEnd_Vel[client] = vecVel;
    }

    new victim_health = GetClientHealth(victim);
    Goomba_Fakekill[victim] = 1;
    SDKHooks_TakeDamage(victim,
                        client,
                        client,
                        victim_health * damageMultiplier + damageBonus,
                        DMG_PREVENT_PHYSICS_FORCE | DMG_CRUSH | DMG_ALWAYSGIB);

    Goomba_Fakekill[victim] = 0;

    return true;
}

public PlayReboundSound(Handle:hPlugin, numParams)
{
    if(numParams != 1)
    {
        return;
    }

    new client = GetNativeCell(1);

    if (IsClientInGame(client))
    {
        if(GetConVarBool(g_Cvar_SoundsEnabled))
        {
            EmitSoundToAll(REBOUND_SOUND, client);
        }
    }
}

public PlayStompSound(Handle:hPlugin, numParams)
{
    if(numParams != 1)
    {
        return;
    }

    new client = GetNativeCell(1);

    if (IsClientInGame(client) && IsPlayerAlive(client))
    {
        if(GetConVarBool(g_Cvar_SoundsEnabled))
        {
            EmitSoundToClient(client, STOMP_SOUND, client);
        }
    }
}

public OnPreThinkPost(client)
{
    if (IsClientInGame(client) && IsPlayerAlive(client))
    {
        if(g_TeleportAtFrameEnd[client])
        {
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, g_TeleportAtFrameEnd_Vel[client]);

            if(GetConVarBool(g_Cvar_SoundsEnabled))
            {
                EmitSoundToAll(REBOUND_SOUND, client);
            }
        }
    }
    g_TeleportAtFrameEnd[client] = false;
}


public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    decl String:strCookie[16];
    GetClientCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

    //-----------------------------------------------------
    // on       = Immunity enabled
    // off      = Immunity disabled
    // next_on  = Immunity enabled on respawn
    // next_off = Immunity disabled on respawn
    //-----------------------------------------------------

    if(StrEqual(strCookie, ""))
    {
        SetClientCookie(client, g_Cookie_ClientPref, "off");
    }
    else if(StrEqual(strCookie, "next_off"))
    {
        SetClientCookie(client, g_Cookie_ClientPref, "off");
    }
    else if(StrEqual(strCookie, "next_on"))
    {
        SetClientCookie(client, g_Cookie_ClientPref, "on");
    }
}

public Action:Cmd_GoombaToggle(client, args)
{
    if(GetConVarBool(g_Cvar_ImmunityEnabled))
    {
        decl String:strCookie[16];
        GetClientCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

        if(StrEqual(strCookie, "off") || StrEqual(strCookie, "next_off"))
        {
            SetClientCookie(client, g_Cookie_ClientPref, "next_on");
            ReplyToCommand(client, "%t", "Immun On");
        }
        else
        {
            SetClientCookie(client, g_Cookie_ClientPref, "next_off");
            ReplyToCommand(client, "%t", "Immun Off");
        }
    }
    else
    {
        ReplyToCommand(client, "%t", "Immun Disabled");
    }
    return Plugin_Handled;
}

public Action:Cmd_GoombaOn(client, args)
{
    if(GetConVarBool(g_Cvar_ImmunityEnabled))
    {
        decl String:strCookie[16];
        GetClientCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

        if(!StrEqual(strCookie, "off"))
        {
            SetClientCookie(client, g_Cookie_ClientPref, "next_off");
            ReplyToCommand(client, "%t", "Immun Off");
        }
    }
    else
    {
        ReplyToCommand(client, "%t", "Immun Disabled");
    }
    return Plugin_Handled;
}

public Action:Cmd_GoombaOff(client, args)
{
    if(GetConVarBool(g_Cvar_ImmunityEnabled))
    {
        decl String:strCookie[16];
        GetClientCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

        if(!StrEqual(strCookie, "on"))
        {
            SetClientCookie(client, g_Cookie_ClientPref, "next_on");
            ReplyToCommand(client, "%t", "Immun On");
        }
    }
    else
    {
        ReplyToCommand(client, "%t", "Immun Disabled");
    }
    return Plugin_Handled;
}

public Action:Cmd_GoombaStatus(client, args)
{
    if(GetConVarBool(g_Cvar_ImmunityEnabled))
    {
        decl String:strCookie[16];
        GetClientCookie(client, g_Cookie_ClientPref, strCookie, sizeof(strCookie));

        if(StrEqual(strCookie, "on"))
        {
            ReplyToCommand(client, "%t", "Status Off");
        }
        if(StrEqual(strCookie, "off"))
        {
            ReplyToCommand(client, "%t", "Status On");
        }
        if(StrEqual(strCookie, "next_off"))
        {
            ReplyToCommand(client, "%t", "Status Next On");
        }
        if(StrEqual(strCookie, "next_on"))
        {
            ReplyToCommand(client, "%t", "Status Next Off");
        }
    }
    else
    {
        ReplyToCommand(client, "%t", "Immun Disabled");
    }

    return Plugin_Handled;
}

public Action:Timer_DeleteParticle(Handle:timer, any:ref)
{
    new particle = EntRefToEntIndex(ref);
    DeleteParticle(particle);
}

stock AttachParticle(entity, String:particleType[])
{
    new particle = CreateEntityByName("info_particle_system");
    decl String:tName[128];

    if(IsValidEdict(particle))
    {
        decl Float:pos[3] ;
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
        pos[2] += 74;
        TeleportEntity(particle, pos, NULL_VECTOR, NULL_VECTOR);

        Format(tName, sizeof(tName), "target%i", entity);

        DispatchKeyValue(entity, "targetname", tName);
        DispatchKeyValue(particle, "targetname", "tf2particle");
        DispatchKeyValue(particle, "parentname", tName);
        DispatchKeyValue(particle, "effect_name", particleType);
        DispatchSpawn(particle);

        SetVariantString(tName);
        SetVariantString("flag");
        ActivateEntity(particle);
        AcceptEntityInput(particle, "start");

        return particle;
    }
    return -1;
}

stock DeleteParticle(any:particle)
{
    if (particle > MaxClients && IsValidEntity(particle))
    {
        decl String:classname[256];
        GetEdictClassname(particle, classname, sizeof(classname));

        if (StrEqual(classname, "info_particle_system", false))
        {
            AcceptEntityInput(particle, "Kill");
        }
    }
}

stock MyAddServerTag(const String:tag[])
{
    decl String:currtags[128];
    if (sv_tags == INVALID_HANDLE)
    {
        return;
    }

    GetConVarString(sv_tags, currtags, sizeof(currtags));
    if (StrContains(currtags, tag) > -1)
    {
        // already have tag
        return;
    }

    decl String:newtags[128];
    Format(newtags, sizeof(newtags), "%s%s%s", currtags, (currtags[0]!=0)?",":"", tag);
    new flags = GetConVarFlags(sv_tags);
    SetConVarFlags(sv_tags, flags & ~FCVAR_NOTIFY);
    SetConVarString(sv_tags, newtags);
    SetConVarFlags(sv_tags, flags);
}

stock MyRemoveServerTag(const String:tag[])
{
    decl String:newtags[128];
    if (sv_tags == INVALID_HANDLE)
    {
        return;
    }

    GetConVarString(sv_tags, newtags, sizeof(newtags));
    if (StrContains(newtags, tag) == -1)
    {
        // tag isn't on here, just bug out
        return;
    }

    ReplaceString(newtags, sizeof(newtags), tag, "");
    ReplaceString(newtags, sizeof(newtags), ",,", "");
    new flags = GetConVarFlags(sv_tags);
    SetConVarFlags(sv_tags, flags & ~FCVAR_NOTIFY);
    SetConVarString(sv_tags, newtags);
    SetConVarFlags(sv_tags, flags);
}
