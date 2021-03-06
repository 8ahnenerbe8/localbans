#pragma semicolon 1
#pragma newdecls required

#include <localbans>

#undef REQUIRE_PLUGIN
#include <adminmenu>

public Plugin myinfo =
{
	name = "LocalBans",
	author = "88",
	description = "Basic banning commands using database",
	version = "1.0",
	url = "http://steamcommunity.com/profiles/76561198195411193"
};

static const char DBName[] = "localbans";

Database  g_hDB;
StringMap g_hBanCache;
KeyValues g_hLocalBans;

int       g_iBanTargetUserId[MAXPLAYERS + 1];
int       g_iBanTime[MAXPLAYERS + 1];
bool      g_bWaitForTime[MAXPLAYERS + 1];
bool      g_bWaitForReason[MAXPLAYERS + 1];

char      g_sLoggingPath[PLATFORM_MAX_PATH];

Handle    g_hOnBansLoaded;
Handle    g_hOnBanCreated_Pre;
Handle    g_hOnBanCreated_Post;
Handle    g_hOnBanRemoved_Pre;
Handle    g_hOnBanRemoved_Post;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("localbans");
	
	CreateNative("LB_GetDatabase", Native_GetDatabase);
	CreateNative("LB_GetBanCache", Native_GetBanCache);
	CreateNative("LB_CreateBan", Native_CreateBan);
	CreateNative("LB_RemoveBan", Native_RemoveBan);
	
	g_hOnBansLoaded      = CreateGlobalForward("LB_OnBansLoaded", ET_Ignore);
	g_hOnBanCreated_Pre  = CreateGlobalForward("LB_OnBanCreated_Pre", ET_Hook, Param_String, Param_String);
	g_hOnBanCreated_Post = CreateGlobalForward("LB_OnBanCreated_Post", ET_Ignore, Param_String, Param_String);
	g_hOnBanRemoved_Pre  = CreateGlobalForward("LB_OnBanRemoved_Pre", ET_Hook, Param_String);
	g_hOnBanRemoved_Post = CreateGlobalForward("LB_OnBanRemoved_Post", ET_Ignore, Param_String);
	
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_hBanCache  = new StringMap();
	g_hLocalBans = new KeyValues("localbans");
	
	DB_Connect();

	RegAdminCmd("sm_ban", SM_Ban, ADMFLAG_BAN, "Usage: sm_ban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_addban", SM_AddBan, ADMFLAG_RCON, "Usage: sm_addban <steamid> <time> [reason]");
	RegAdminCmd("sm_banip", SM_BanIp, ADMFLAG_RCON, "Usage: sm_banip <ip> <time> [reason]");
	RegAdminCmd("sm_unban", SM_UnBan, ADMFLAG_UNBAN, "Usage: sm_unban <steamid|ip>");
	RegAdminCmd("sm_searchban", SM_SearchBan, ADMFLAG_UNBAN, "Usage: sm_searchban <steamid|ip>");
	RegAdminCmd("sm_bans", SM_Bans, ADMFLAG_UNBAN, "Opens banlist menu.");
	RegAdminCmd("sm_banlist", SM_Bans, ADMFLAG_UNBAN, "Opens banlist menu.");
	
	TopMenu topmenu;
	if(LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
	{
		OnAdminMenuReady(topmenu);
	}
	
	LoadLogFile();
	LoadTranslations("common.phrases");
}

public void OnConfigsExecuted()
{
	LoadLocalbansConfig();
}

public void OnClientDisconnect(int client)
{
	g_bWaitForTime[client]   = false;
	g_bWaitForReason[client] = false;
}

public void OnClientPostAdminCheck(int client)
{
	SearchBan(client);
}

public void OnAdminMenuReady(Handle topmenu)
{
	TopMenu hTopmenu = TopMenu.FromHandle(topmenu);
	
	TopMenuObject category = hTopmenu.AddCategory("localbans_category", AdminMenu_Localbans, "localbans_adminmenu", ADMFLAG_BAN);

	if(category != INVALID_TOPMENUOBJECT)
	{
		hTopmenu.AddItem("localbans_ban", AdminMenu_Ban, category, "localbans_ban", ADMFLAG_BAN);
		hTopmenu.AddItem("localbans_banlist", AdminMenu_Banlist, category, "localbans_banlist", ADMFLAG_UNBAN);
	}
}

public Action OnClientSayCommand(int client, const char[] command, const char[] args)
{
	if((g_bWaitForTime[client] || g_bWaitForReason[client]) 
	&& (StrEqual(args, "!abortban") || StrEqual(args, "abortban")))
	{
		g_bWaitForTime[client]   = false;
		g_bWaitForReason[client] = false;
		
		PrintToChat(client, "Ban aborted.");
		
		return Plugin_Stop;
	}
	
	if(g_bWaitForTime[client])
	{
		g_bWaitForTime[client] = false;
		
		g_iBanTime[client] = StringToInt(args);
		OpenReasonMenu(client);
		
		return Plugin_Stop;
	}
	
	if(g_bWaitForReason[client])
	{
		g_bWaitForReason[client] = false;
		
		int target = GetClientOfUserId(g_iBanTargetUserId[client]);

		if(target != 0)
		{
			int timestamp = GetTime();
			int seconds   = g_iBanTime[client] * 60;
			char sName[MAX_NAME_LENGTH], sName2[MAX_NAME_LENGTH], sAuth[32], sAuth2[32], sReason[MAX_REASON_LENGTH], sIp[16];
			
			FormatEx(sReason, sizeof(sReason), "%s", (strlen(args) > 1)? args:"N/A");
			GetClientName(target, sName, sizeof(sName));
			GetClientName(client, sName2, sizeof(sName2));
			GetClientAuthId(target, AuthId_Steam2, sAuth, sizeof(sAuth));
			GetClientAuthId(client, AuthId_Steam2, sAuth2, sizeof(sAuth2));
			GetClientIP(target, sIp, sizeof(sIp), true);
			
			DB_CreateBan(sAuth, sIp, seconds, BAN_DEFAULT, sName, timestamp, sReason, sAuth2, sName2);
			LogBan(BAN_DEFAULT, sName2, sAuth2, sName, sAuth, g_iBanTime[client], sReason);
			AdvancedKickClient(target, sReason, sName2, g_iBanTime[client], timestamp + seconds);
			BanNotify(sReason, sName, g_iBanTime[client]);
		}
		else
		{
			ReplyToCommand(client, "The player you selected is no longer available.");
		}

		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

public Action SM_Ban(int client, int args)
{
	if(args < 2)
	{
		if(client == 0)
		{
			ReplyToCommand(client, "Usage: sm_ban <#userid|name> <minutes|0> [reason]");
		}
		else
		{
			OpenPlayersMenu(client);
		}
		
		return Plugin_Handled;
	}
	
	int target, time;
	char sArg[256], sReason[MAX_REASON_LENGTH];
	GetCmdArgString(sArg, sizeof(sArg));
	ParseArgument(BAN_DEFAULT, sArg, client, target, _, _, time, sReason, sizeof(sReason));

	if(target == -1)
	{
		ReplyToCommand(client, "Cannot find the target.");
		return Plugin_Handled;
	}
	
	FormatEx(sReason, sizeof(sReason), "%s", (strlen(sReason) > 1)? sReason:"N/A");
	
	char sName[MAX_NAME_LENGTH], sName2[MAX_NAME_LENGTH], sAuth[32], sIp[16];
	GetClientName(target, sName, sizeof(sName));
	GetClientName(client, sName2, sizeof(sName2));
	GetClientAuthId(target, AuthId_Steam2, sAuth, sizeof(sAuth));
	GetClientIP(target, sIp, sizeof(sIp), true);

	int timestamp = GetTime();
	int seconds   = time * 60;
	
	if(client == 0)
	{
		DB_CreateBan(sAuth, sIp, seconds, BAN_DEFAULT, sName, timestamp, sReason, "Console", sName2);
		LogBan(BAN_DEFAULT, sName2, "Console", sName, sAuth, time, sReason);
	}
	else
	{
		char sAuth2[32];
		GetClientAuthId(client, AuthId_Steam2, sAuth2, sizeof(sAuth2));
		
		DB_CreateBan(sAuth, sIp, seconds, BAN_DEFAULT, sName, timestamp, sReason, sAuth2, sName2);
		LogBan(BAN_DEFAULT, sName2, sAuth2, sName, sAuth, time, sReason);
	}

	AdvancedKickClient(target, sReason, sName2, time, timestamp + time);
	BanNotify(sReason, sName, time);

	return Plugin_Handled;
}

public Action SM_AddBan(int client, int args)
{
	if(args < 2)
	{
		ReplyToCommand(client, "Usage: sm_addban <steamid> <time> [reason]");
		return Plugin_Handled;
	}
	
	int time;
	char sArg[256], sAuth[32], sReason[MAX_REASON_LENGTH];
	GetCmdArgString(sArg, sizeof(sArg));
	ParseArgument(BAN_STEAMID, sArg, client, _, sAuth, sizeof(sAuth), time, sReason, sizeof(sReason));
	
	if(StrContains(sAuth, "STEAM_") == -1)
	{
		ReplyToCommand(client, "Invalid SteamID format.");
		return Plugin_Handled;
	}
	
	FormatEx(sReason, sizeof(sReason), "%s", (strlen(sReason) > 1)? sReason:"N/A");
	
	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	int timestamp = GetTime();
	int seconds   = time * 60;
	
	if(client == 0)
	{
		DB_CreateBan(sAuth, _, seconds, BAN_STEAMID, _, timestamp, sReason, "Console", sName);
		LogBan(BAN_STEAMID, sName, "Console", _, sAuth, time, sReason);
	}
	else
	{
		char sAuth2[32];
		GetClientAuthId(client, AuthId_Steam2, sAuth2, sizeof(sAuth2));
		
		DB_CreateBan(sAuth, _, seconds, BAN_STEAMID, _, timestamp, sReason, sAuth2, sName);
		LogBan(BAN_STEAMID, sName, sAuth2, _, sAuth, time, sReason);
	}
	
	ReplyToCommand(client, "Ban has been added.");
	
	return Plugin_Handled;
}

public Action SM_BanIp(int client, int args)
{
	if(args < 2)
	{
		ReplyToCommand(client, "Usage: sm_banip <ip> <time> [reason]");
		return Plugin_Handled;
	}
	
	int time;
	char sArg[256], sIp[16], sReason[MAX_REASON_LENGTH];
	GetCmdArgString(sArg, sizeof(sArg));
	ParseArgument(BAN_IP, sArg, client, _, sIp, sizeof(sIp), time, sReason, sizeof(sReason));
	
	FormatEx(sReason, sizeof(sReason), "%s", (strlen(sReason) > 1)? sReason:"N/A");
	
	char sName[MAX_NAME_LENGTH];
	GetClientName(client, sName, sizeof(sName));

	int timestamp = GetTime();
	int seconds   = time * 60;
	
	if(client == 0)
	{
		DB_CreateBan(_, sIp, seconds, BAN_IP, _, timestamp, sReason, "Console", sName);
		LogBan(BAN_IP, sName, "Console", _, sIp, time, sReason);
	}
	else
	{
		char sAuth[32];
		GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth));
		
		DB_CreateBan(_, sIp, seconds, BAN_IP, _, timestamp, sReason, sAuth, sName);
		LogBan(BAN_IP, sName, sAuth, _, sIp, time, sReason);
	}
	
	ReplyToCommand(client, "Ban has been added.");
	
	return Plugin_Handled;
}

public Action SM_UnBan(int client, int args)
{
	if(args < 1)
	{
		ReplyToCommand(client, "Usage: sm_unban <steamid|ip>");
		return Plugin_Handled;
	}
	
	char sArg[32], sName[MAX_NAME_LENGTH];
	GetCmdArgString(sArg, sizeof(sArg));
	
	DB_RemoveBan(sArg);
	
	GetClientName(client, sName, sizeof(sName));

	if(client == 0)
	{
		LogUnban(sName, "Console", sArg);
	}
	else
	{
		char sAuth[32];
		GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth));
		LogUnban(sName, sAuth, sArg);
	}
	
	ReplyToCommand(client, "Removed bans matching filter: %s", sArg);

	return Plugin_Handled;
}

public Action SM_SearchBan(int client, int args)
{
	if(args < 1)
	{
		ReplyToCommand(client, "Usage: sm_searchban <steamid|ip>");
		return Plugin_Handled;
	}
	
	bool has;
	int totalBans, activeBans;
	char sAuth[32], sKey[16], sAuth2[32], sIp[16];
	any[] pack = new any[BanCache];
	GetCmdArgString(sAuth, sizeof(sAuth));
	
	for(int idx, size = g_hBanCache.Size; idx < size; idx++)
	{
		IntToString(idx, sKey, sizeof(sKey));
		g_hBanCache.GetArray(sKey, pack, view_as<int>(BanCache));
		
		FormatEx(sAuth2, sizeof(sAuth2), "%s", pack[Auth]);
		FormatEx(sIp, sizeof(sIp), "%s", pack[Ip]);
		
		if(StrEqual(sAuth, sAuth2) || StrEqual(sAuth, sIp))
		{
			if(client == 0)
			{	
				++totalBans;
				
				if(IsActiveBan(pack[Type], pack[Timestamp], pack[Time]))
				{
					++activeBans;
				}
			}
			else
			{
				has = true;
				break;
			}
		}
	}
	
	if(client == 0)
	{
		if(totalBans == 0)
		{
			PrintToServer("No results found for your query.");
		}
		else
		{
			PrintToServer("Total bans: %d, active bans: %d.", totalBans, activeBans);
		}
	}
	else
	{
		OpenBanlistMenu(client, has, _, true, sAuth);
	}
	
	return Plugin_Handled;
}

public Action SM_Bans(int client, int args)
{
	if(client != 0)
	{
		OpenTypeMenu(client);
	}
	
	return Plugin_Handled;
}

public void AdminMenu_Localbans(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "LocalBans");
	}
	else if(action == TopMenuAction_DisplayTitle)
	{
		FormatEx(buffer, maxlength, "LocalBans\n \n");
	}
}

public void AdminMenu_Ban(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int client, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "Ban player");
	}
	else if(action == TopMenuAction_SelectOption)
	{
		OpenPlayersMenu(client);
	}
}

public void AdminMenu_Banlist(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int client, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "Banlist");
	}
	else if(action == TopMenuAction_SelectOption)
	{
		OpenTypeMenu(client);
	}
}

void OpenPlayersMenu(int client)
{
	Menu menu = new Menu(Menu_Players);
	menu.SetTitle("Ban player\n \n");
	
	char sName[MAX_NAME_LENGTH], sInfo[8];
	for(int target = 1; target <= MaxClients; target++)
	{
		if(IsClientInGame(target) && !IsFakeClient(target) && CanUserTarget(client, target))
		{
			GetClientName(target, sName, sizeof(sName));
			IntToString(GetClientUserId(target), sInfo, sizeof(sInfo));
			menu.AddItem(sInfo, sName);
		}
	}
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Players(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
	
		g_iBanTargetUserId[client] = StringToInt(sInfo);
		OpenBanTimeMenu(client);
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

void OpenBanTimeMenu(int client)
{
	Menu menu = new Menu(Menu_BanTimes);
	menu.SetTitle("Ban time\n \n");
	
	menu.AddItem("", "Custom time (type in chat)");
	
	char timeName[32], time[16];
	
	g_hLocalBans.JumpToKey("bantimes");
	g_hLocalBans.GotoFirstSubKey(false);
	
	do
	{
		g_hLocalBans.GetSectionName(time, sizeof(time));
		g_hLocalBans.GetString(NULL_STRING, timeName, sizeof(timeName));
		
		menu.AddItem(time, timeName);
	}
	while(g_hLocalBans.GotoNextKey(false));
	
	g_hLocalBans.Rewind();

	menu.ExitButton = true;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_BanTimes(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		if(param2 == 0)
		{
			PrintToChat(client, "Enter the time as a chat message. Use !abortban to abort this.");
			g_bWaitForTime[client] = true;
		}
		else
		{
			char sInfo[16];
			menu.GetItem(param2, sInfo, sizeof(sInfo));
			
			g_iBanTime[client] = StringToInt(sInfo);
			OpenReasonMenu(client);
		}
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenPlayersMenu(client);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

void OpenReasonMenu(int client)
{
	Menu menu = new Menu(Menu_Reason);
	menu.SetTitle("Ban reason\n \n");

	menu.AddItem("", "Custom reason (type in chat)");
	
	char reasonName[MAX_REASON_LENGTH], reasonFull[MAX_REASON_LENGTH];
	
	g_hLocalBans.JumpToKey("banreasons");
	g_hLocalBans.GotoFirstSubKey(false);
	
	do
	{
		g_hLocalBans.GetSectionName(reasonFull, sizeof(reasonFull));
		g_hLocalBans.GetString(NULL_STRING, reasonName, sizeof(reasonName));
		
		menu.AddItem(reasonFull, reasonName);
	}
	while(g_hLocalBans.GotoNextKey(false));
	
	g_hLocalBans.Rewind();
	
	menu.ExitButton = true;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Reason(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		if(param2 == 0)
		{
			PrintToChat(client, "Enter the reason as a chat message. Use !abortban to abort this.");
			g_bWaitForReason[client] = true;
		}
		else
		{
			int target = GetClientOfUserId(g_iBanTargetUserId[client]);
			
			if(target != 0)
			{
				int seconds   = g_iBanTime[client] * 60;
				int timestamp = GetTime();
				char sName[MAX_NAME_LENGTH], sName2[MAX_NAME_LENGTH], sAuth[32], sAuth2[32], sReason[MAX_REASON_LENGTH], sIp[16];
				
				menu.GetItem(param2, sReason, sizeof(sReason));
				GetClientName(target, sName, sizeof(sName));
				GetClientName(client, sName2, sizeof(sName2));
				GetClientAuthId(target, AuthId_Steam2, sAuth, sizeof(sAuth));
				GetClientAuthId(client, AuthId_Steam2, sAuth2, sizeof(sAuth2));
				GetClientIP(target, sIp, sizeof(sIp), true);
				
				DB_CreateBan(sAuth, sIp, seconds, BAN_DEFAULT, sName, timestamp, sReason, sAuth2, sName2);
				LogBan(BAN_DEFAULT, sName2, sAuth2, sName, sAuth, g_iBanTime[client], sReason);
				AdvancedKickClient(target, sReason, sName2, g_iBanTime[client], timestamp + seconds);
				BanNotify(sReason, sName, g_iBanTime[client]);
			}
			else
			{
				ReplyToCommand(client, "The player you selected is no longer available.");
			}
		}
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenBanTimeMenu(client);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

void OpenTypeMenu(int client)
{
	Menu menu = new Menu(Menu_ShowMode);
	menu.SetTitle("Select banlist type\n \n");
	
	menu.AddItem("", "Active bans");
	menu.AddItem("", "All bans");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_ShowMode(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		bool has;
		int size = g_hBanCache.Size;
		
		if(param2 == 0)
		{
			char sKey[16];
			any[] pack = new any[BanCache];
			
			for(int idx; idx < size; idx++)
			{
				IntToString(idx, sKey, sizeof(sKey));
				g_hBanCache.GetArray(sKey, pack, view_as<int>(BanCache));
				
				if(IsActiveBan(pack[Type], pack[Timestamp], pack[Time]))
				{
					has = true;
					break;
				}
			}
		}
		else
		{
			if(size > 0)
			{	
				has = true;
			}
		}
		
		OpenBanlistMenu(client, has, param2);
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

void OpenBanlistMenu(int client, bool hasBans, int showmode = -1, bool special = false, const char[] auth = NULL_STRING)
{
	Menu menu = new Menu(Menu_ShowBans);
	menu.SetTitle("Banlist\n \n");
	
	if(hasBans)
	{
		char sKey[16], sInfo[300], sItem[64], sAuth[32], sIp[16];
		any[] pack = new any[BanCache];
		
		for(int idx, size = g_hBanCache.Size, item; idx < size; idx++)
		{
			IntToString(idx, sKey, sizeof(sKey));
			g_hBanCache.GetArray(sKey, pack, view_as<int>(BanCache));
			
			if(special)
			{
				FormatEx(sAuth, sizeof(sAuth), "%s", pack[Auth]);
				FormatEx(sIp, sizeof(sIp), "%s", pack[Ip]);
				
				if(!StrEqual(auth, sAuth) && !StrEqual(auth, sIp))
				{
					continue;
				}
			}
			else
			{
				if(showmode == 0 && !IsActiveBan(pack[Type], pack[Timestamp], pack[Time]))
				{
					continue;
				}
			}
			
			FormatEx(sInfo, sizeof(sInfo), "%s;%s;%s;%s;%d;%d;%s;%s;%d", pack[Auth], pack[Ip], pack[Name], pack[Reason], pack[Timestamp], pack[Time], pack[AdminAuth], pack[AdminName], pack[Type]);
			FormatEx(sItem, sizeof(sItem), "#%d: %s", ++item, pack[Name]);
			menu.AddItem(sInfo, sItem);
		}
	}
	else
	{
		menu.AddItem("", "There are no bans yet.", ITEMDRAW_DISABLED);
	}
	
	menu.ExitBackButton = !special;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_ShowBans(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[300];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		ShowBanInfo(client, sInfo);
	}
	else if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
		{
			OpenTypeMenu(client);
		}
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

/*
	Auth        0
	Ip          1
	Name        2
	Reason      3
	Timestamp   4
	Time        5
	AdminAuth   6
	AdminName   7
	Type        8
*/

void ShowBanInfo(int client, const char[] info)
{
	char sExplode[9][MAX_REASON_LENGTH];
	ExplodeString(info, ";", sExplode, sizeof(sExplode), sizeof(sExplode[]));
	
	BanType type = view_as<BanType>(StringToInt(sExplode[8]));
	int date     = StringToInt(sExplode[4]);
	int time     = StringToInt(sExplode[5]);
	
	char sDate[32], sUnban[32];
	FormatTime(sDate, sizeof(sDate), "%x %X", date);
	if(time == 0)
	{
		FormatEx(sUnban, sizeof(sUnban), "Permanent");
	}
	else
	{
		FormatTime(sUnban, sizeof(sUnban), "%x %X", date + time);
	}
	
	char sTitle[400];
	FormatEx(sTitle, sizeof(sTitle), "Ban information of %s\n \n", sExplode[2]);
	
	Format(sTitle, sizeof(sTitle), "%sAuth: %s\n", sTitle, sExplode[0]);
	Format(sTitle, sizeof(sTitle), "%sIP: %s\n", sTitle, sExplode[1]);
	Format(sTitle, sizeof(sTitle), "%sReason: %s\n \n", sTitle, sExplode[3]);
	
	Format(sTitle, sizeof(sTitle), "%sDate: %s\n", sTitle, sDate);
	Format(sTitle, sizeof(sTitle), "%sTime: %d min\n", sTitle, time / 60);
	Format(sTitle, sizeof(sTitle), "%sUnban: %s\n \n", sTitle, sUnban);
	
	Format(sTitle, sizeof(sTitle), "%sBanned by: %s (%s)\n \n", sTitle, sExplode[7], sExplode[6]);
	
	Menu menu = new Menu(Menu_BanInfo);
	menu.SetTitle(sTitle);
	
	char sInfo[32];
	FormatEx(sInfo, sizeof(sInfo), "%s", (type == BAN_IP)? sExplode[1]:sExplode[0]);
	menu.AddItem(sInfo, "Unban", (IsActiveBan(type, date, time))? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_BanInfo(Menu menu, MenuAction action, int client, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));
		
		DB_RemoveBan(sInfo);
		PrintToChat(client, "Ban has been removed.");
	}
	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

void DB_Connect()
{
	char sError[128];
	g_hDB = SQLite_UseDatabase(DBName, sError, sizeof(sError));
	
	if(g_hDB == null)
	{
		SetFailState(sError);
		return;
	}
	
	DB_CreateTable();
	DB_LoadBans();
}

void DB_CreateTable()
{
	char sQuery[400];
	FormatEx(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `%s` (`Id` INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, `Auth` VARCHAR(32) NOT NULL, `Ip` VARCHAR(16) NOT NULL, `Time` INTEGER NOT NULL, `Type` INTEGER NOT NULL, `Name` VARCHAR(%d) NOT NULL, `Timestamp` INTEGER NOT NULL, `Reason` VARCHAR(%d) NOT NULL, `AdminAuth` VARCHAR(32) NOT NULL, `AdminName` VARCHAR(%d) NOT NULL);", 
		DBName,
		MAX_NAME_LENGTH,
		MAX_REASON_LENGTH,
		MAX_NAME_LENGTH); 

	g_hDB.Query(DB_CreateTable_Callback, sQuery);
}

public void DB_CreateTable_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("DB_CreateTable_Callback: %s", error);
	}
}

void DB_LoadBans()
{
	char sQuery[128];
	FormatEx(sQuery, sizeof(sQuery), "SELECT `Auth`, `Ip`, `Time`, `Type`, `Name`, `Timestamp`, `Reason`, `AdminAuth`, `AdminName` FROM `%s`;", DBName);
	
	g_hDB.Query(DB_LoadBans_Callback, sQuery);
}

public void DB_LoadBans_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results != null)
	{
		g_hBanCache.Clear();

		char sKey[16];
		any[] pack = new any[BanCache];
		
		while(results.FetchRow())
		{
			results.FetchString(0, pack[Auth], 32);
			results.FetchString(1, pack[Ip], 16);
			pack[Time] = results.FetchInt(2);
			pack[Type] = view_as<BanType>(results.FetchInt(3));
			results.FetchString(4, pack[Name], MAX_NAME_LENGTH);
			pack[Timestamp] = results.FetchInt(5);
			results.FetchString(6, pack[Reason], MAX_REASON_LENGTH);
			results.FetchString(7, pack[AdminAuth], 32);
			results.FetchString(8, pack[AdminName], MAX_NAME_LENGTH);
			
			IntToString(g_hBanCache.Size, sKey, sizeof(sKey));
			g_hBanCache.SetArray(sKey, pack, view_as<int>(BanCache));
		}
		
		Call_StartForward(g_hOnBansLoaded);
		Call_Finish();
	}
	else
	{
		LogError("DB_LoadBans_Callback: %s", error);
	}
}

void DB_CreateBan(const char[] auth = "N/A", const char[] ip = "N/A", int time, BanType type, const char[] name = "N/A", int timestamp, const char[] reason = "N/A", const char[] adminAuth, const char[] adminName)
{
	Call_StartForward(g_hOnBanCreated_Pre);
	Call_PushString(auth);
	Call_PushString(ip);
	
	Action result;
	Call_Finish(result);
	
	if(result != Plugin_Handled)
	{
		DataPack data = new DataPack();
		data.WriteString(auth);
		data.WriteString(ip);
		data.WriteCell(time);
		data.WriteCell(type);
		data.WriteString(name);
		data.WriteCell(timestamp);
		data.WriteString(reason);
		data.WriteString(adminAuth);
		data.WriteString(adminName);
		
		char sQuery[500];
		FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `%s` (`Auth`, `Ip`, `Time`, `Type`, `Name`, `Timestamp`, `Reason`, `AdminAuth`, `AdminName`) VALUES ('%s', '%s', '%d', '%d', '%s', '%d', '%s', '%s', '%s');", 
			DBName,
			auth,
			ip,
			time,
			type,
			name,
			timestamp,
			reason,
			adminAuth,
			adminName);
			
		g_hDB.Query(DB_CreateBan_Callback, sQuery, data);
	}
}

public void DB_CreateBan_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	if(results != null)
	{
		char sAuth[32], sIp[16], sName[MAX_NAME_LENGTH], sReason[MAX_REASON_LENGTH], sAdminAuth[32], sAdminName[MAX_NAME_LENGTH], sKey[16];
		
		data.Reset();
		data.ReadString(sAuth, sizeof(sAuth));
		data.ReadString(sIp, sizeof(sIp));
		int time = data.ReadCell();
		BanType type = data.ReadCell();
		data.ReadString(sName, sizeof(sName));
		int timestamp = data.ReadCell();
		data.ReadString(sReason, sizeof(sReason));
		data.ReadString(sAdminAuth, sizeof(sAdminAuth));
		data.ReadString(sAdminName, sizeof(sAdminName));
		
		any[] pack = new any[BanCache];
		
		FormatEx(pack[Auth], 32, "%s", sAuth);
		FormatEx(pack[Ip], 16, "%s", sIp);
		pack[Time] = time;
		pack[Type] = type;
		FormatEx(pack[Name], MAX_NAME_LENGTH, "%s", sName);
		pack[Timestamp] = timestamp;
		FormatEx(pack[Reason], MAX_REASON_LENGTH, "%s", sReason);
		FormatEx(pack[AdminAuth], 32, "%s", sAdminAuth);
		FormatEx(pack[AdminName], MAX_NAME_LENGTH, "%s", sAdminName);

		IntToString(g_hBanCache.Size, sKey, sizeof(sKey));
		g_hBanCache.SetArray(sKey, pack, view_as<int>(BanCache));
		
		Call_StartForward(g_hOnBanCreated_Post);
		Call_PushString(sAuth);
		Call_PushString(sIp);
		Call_Finish();
	}
	else
	{
		LogError("DB_CreateBan_Callback: %s", error);
	}
	
	delete data;
}

void DB_RemoveBan(const char[] auth)
{
	Call_StartForward(g_hOnBanRemoved_Pre);
	Call_PushString(auth);
	
	Action result;
	Call_Finish(result);
	
	if(result != Plugin_Handled)
	{
		DataPack data = new DataPack();
		data.WriteString(auth);
		
		char sQuery[128];
		FormatEx(sQuery, sizeof(sQuery), "UPDATE `%s` SET `Type` = '%d' WHERE `Auth` = '%s' OR `Ip` = '%s';", DBName, BAN_NONE, auth, auth);
		g_hDB.Query(DB_UpdateBan_Callback, sQuery, data);
	}
}

public void DB_UpdateBan_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	if(results != null)
	{
		any[] pack = new any[BanCache];
		char sKey[16], sAuth[32], sAuth2[32], sIp[16];
		
		data.Reset();
		data.ReadString(sAuth, sizeof(sAuth));
		
		for(int idx, size = g_hBanCache.Size; idx < size; idx++)
		{
			IntToString(idx, sKey, sizeof(sKey));
			g_hBanCache.GetArray(sKey, pack, view_as<int>(BanCache));
			
			if(!IsActiveBan(pack[Type], pack[Timestamp], pack[Time]))
			{
				continue;
			}
			
			FormatEx(sAuth2, sizeof(sAuth2), "%s", pack[Auth]);
			FormatEx(sIp, sizeof(sIp), "%s", pack[Ip]);
			
			if(StrEqual(sAuth2, sAuth) || StrEqual(sIp, sAuth))
			{
				pack[Type] = BAN_NONE;
				g_hBanCache.SetArray(sKey, pack, view_as<int>(BanCache));
			}
		}
		
		Call_StartForward(g_hOnBanRemoved_Post);
		Call_PushString(sAuth);
		Call_Finish();
	}
	else
	{
		LogError("DB_UpdateBan_Callback: %s", error);
	}
	
	delete data;
}

void LoadLocalbansConfig()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/localbans.cfg");
	
	if(!FileExists(sPath) && !FileExists(sPath, true))
	{
		SetFailState("%s not exists.", sPath);
		return;
	}

	if(g_hLocalBans.ImportFromFile(sPath))
	{
		if(!g_hLocalBans.JumpToKey("bantimes", false) || !g_hLocalBans.GotoFirstSubKey(false))
		{
			SetFailState("Error in %s: Couldn't find 'bantimes' or their stuff.", sPath);
			return;
		}

		g_hLocalBans.Rewind();
		
		if(!g_hLocalBans.JumpToKey("banreasons", false) || !g_hLocalBans.GotoFirstSubKey(false))
		{
			SetFailState("Error in %s: Couldn't find 'banreasons' or their stuff.", sPath);
			return;
		}
		
		g_hLocalBans.Rewind();
	}
	else
	{
		SetFailState("Something went wrong reading from the %s.", sPath);
		return;
	}
}

void LoadLogFile()
{
	BuildPath(Path_SM, g_sLoggingPath, sizeof(g_sLoggingPath), "logs/localbans/localbans.txt");
	
	if(!FileExists(g_sLoggingPath) && !FileExists(g_sLoggingPath, true))
	{
		LogError("Bans logging is disabled because %s not exists", g_sLoggingPath);
	}
}

void SearchBan(int target)
{
	any[] pack = new any[BanCache];
	
	char sKey[16], sAuth[32], sAuth2[32], sIp[16], sIp2[16];
	GetClientAuthId(target, AuthId_Steam2, sAuth, sizeof(sAuth));
	GetClientIP(target, sIp, sizeof(sIp), true);
	
	for(int idx, size = g_hBanCache.Size; idx < size; idx++)
	{
		IntToString(idx, sKey, sizeof(sKey));
		g_hBanCache.GetArray(sKey, pack, view_as<int>(BanCache));

		if(!IsActiveBan(pack[Type], pack[Timestamp], pack[Time]))
		{
			continue;
		}
		
		FormatEx(sAuth2, sizeof(sAuth2), "%s", pack[Auth]);
		FormatEx(sIp2, sizeof(sIp2), "%s", pack[Ip]);
		
		bool auth = StrEqual(sAuth, sAuth2)? true:false;
		bool ip   = StrEqual(sIp, sIp2)? true:false;
		
		g_hLocalBans.Rewind();
		int checkMode = g_hLocalBans.GetNum("check_mode");
		
		if((pack[Type] == BAN_DEFAULT && ((checkMode == 0 && auth) || (checkMode == 1 && (auth || ip))))
		|| (pack[Type] == BAN_STEAMID && auth)
		|| (pack[Type] == BAN_IP && ip))
		{
			AdvancedKickClient(target, pack[Reason], pack[AdminName], pack[Time], pack[Timestamp] + pack[Time]);
			return;
		}
	}
}

void AdvancedKickClient(int target, const char[] reason, const char[] name, int time, int unbanTime)
{
	char sUnban[32];
	if(time == 0)
	{
		FormatEx(sUnban, sizeof(sUnban), "Permanent");
	}
	else
	{
		FormatTime(sUnban, sizeof(sUnban), "%x %X", unbanTime);
	}
	
	KickClient(target, "You are banned from this server.\nReason: %s\nBanned by: %s\nUnban: %s", reason, name, sUnban);
}

void BanNotify(const char[] reason, const char[] name, int time)
{
	if(time == 0)
	{
		PrintToChatAll("Permanently banned player %s. (Reason: %s)", name, reason);
	}
	else
	{
		PrintToChatAll("Banned player %s for %d minutes. (Reason: %s)", name, time, reason);
	}
}

void LogBan(BanType type, const char[] adminName, const char[] adminAuth, const char[] name = NULL_STRING, const char[] auth, int time, const char[] reason)
{
	if(type == BAN_DEFAULT)
	{
		LogToFile(g_sLoggingPath, "Admin %s(%s) banned %s(%s) (minutes: %d) (reason: %s)", adminName, adminAuth, name, auth, time, reason);
	}
	else
	{
		LogToFile(g_sLoggingPath, "Admin %s(%s) added ban (%s: %s) (minutes: %d) (reason: %s)", adminName, adminAuth, (type == BAN_STEAMID)? "SteamID":"IP", auth, time, reason);
	}
}

void LogUnban(const char[] name, const char[] auth, const char[] filter)
{
	LogToFile(g_sLoggingPath, "Admin %s(%s) removed ban (filter: %s)", name, auth, filter);
}

void ParseArgument(BanType type, char[] arg, int client, int &target = -1, char[] auth = NULL_STRING, int authLen = 0, int &time, char[] reason, int reasonLen)
{
	char sTarget[MAX_NAME_LENGTH];
	int len = BreakString(arg, sTarget, sizeof(sTarget));

	if(type == BAN_DEFAULT)
	{
		target = FindTarget(client, sTarget, true);
	}
	else
	{
		FormatEx(auth, authLen, "%s", sTarget);
	}

	int nextLen;
	char sTime[16];
	if((nextLen = BreakString(arg[len], sTime, sizeof(sTime))) != -1)
	{
		len += nextLen;
	}
	else
	{
		len = 0;
		arg[0] = '\0';
	}

	time = StringToInt(sTime);
	FormatEx(reason, reasonLen, "%s", arg[len]);
}

bool IsActiveBan(BanType type, int timestamp, int time)
{
	return (type != BAN_NONE && (time == 0 || (timestamp + time) >= GetTime()));
}

public int Native_GetDatabase(Handle plugin, int numParams)
{
	return view_as<int>(CloneHandle(g_hDB, plugin));
}

public int Native_GetBanCache(Handle plugin, int numParams)
{
	return view_as<int>(CloneHandle(g_hBanCache, plugin));
}

public int Native_CreateBan(Handle plugin, int numParams)
{
	char sAuth[32], sIp[16], sName[MAX_NAME_LENGTH], sReason[MAX_REASON_LENGTH], sAdminAuth[32], sAdminName[MAX_NAME_LENGTH];
	GetNativeString(1, sAuth, sizeof(sAuth));
	GetNativeString(2, sIp, sizeof(sIp));
	GetNativeString(5, sName, sizeof(sName));
	GetNativeString(7, sReason, sizeof(sReason));
	GetNativeString(8, sAdminAuth, sizeof(sAdminAuth));
	GetNativeString(9, sAdminName, sizeof(sAdminName));
	
	DB_CreateBan(sAuth, sIp, GetNativeCell(3), GetNativeCell(4), sName, GetNativeCell(6), sReason, sAdminAuth, sAdminName);
	
	return 0;
}

public int Native_RemoveBan(Handle plugin, int numParams)
{
	char sAuth[32];
	GetNativeString(1, sAuth, sizeof(sAuth));
	
	DB_RemoveBan(sAuth);
	
	return 0;
}