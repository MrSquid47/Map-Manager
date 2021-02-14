#pragma semicolon 1
#pragma dynamic 32768

#define DEBUG

#define PLUGIN_AUTHOR "MrSquid"
#define PLUGIN_VERSION "1.0.1"

#define MAX_MAP_DOWNLOAD 64

#define MAP_INVALID 0
#define MAP_DOWNLOADING 1
#define MAP_SUCCESS 2
#define MAP_FAILED 3

#include <sourcemod>
#include <SteamWorks>

#pragma newdecls required

public Plugin myinfo = 
{
	name = "Map Manager", 
	author = PLUGIN_AUTHOR, 
	description = "download/delete maps", 
	version = PLUGIN_VERSION, 
	url = ""
};

ConVar cvar_FastDL,
cvar_MapList;

int g_iMapDownloadIndex = 1;

ArrayList g_aMapList;

enum struct MapDownload {
	char sMapName[64];
	int iIndex;
	int iStatus;
	int iTime;

	Handle hRequest;
}

MapDownload g_eMaps[MAX_MAP_DOWNLOAD];

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	
	CreateConVar("mapmanager_version", PLUGIN_VERSION, "version", FCVAR_SPONLY | FCVAR_UNLOGGED | FCVAR_DONTRECORD | FCVAR_REPLICATED | FCVAR_NOTIFY);
	cvar_FastDL = CreateConVar("sm_mapmanager_fastdl", "http://cdn.jumpacademy.tf/fastdl/maps/", "FastDL server to download from", FCVAR_NONE);
	cvar_MapList = CreateConVar("sm_mapmanager_maplist", "http://cdn.jumpacademy.tf/?map=list", "Map list download", FCVAR_NONE);
	
	RegAdminCmd("sm_dlmap", Command_dlMap, ADMFLAG_RCON, "download map");
	RegAdminCmd("sm_refreshmaps", Command_refreshMaps, ADMFLAG_RCON, "refresh map list");
	RegAdminCmd("sm_maplog", Command_mapLog, ADMFLAG_RCON, "map download log");
	RegAdminCmd("sm_rmmap", Command_rmMap, ADMFLAG_RCON, "remove map");
	RegAdminCmd("sm_searchmaps", Command_searchMaps, ADMFLAG_RCON, "search map list");

	g_aMapList = new ArrayList(64, 0);
	GetMapList();

	CreateTimer(120.0, Timer_updateMapList, _, TIMER_REPEAT);
}

public Action Command_dlMap(int iClient, int args)
{
	if (args < 1)
	{
		ReplyToCommand(iClient, "[SM] Usage: sm_dlmap [map name]");
		return Plugin_Handled;
	}

	if (GetNextMapIndex() == -1)
	{
		ReplyToCommand(iClient, "[SM] Maximum concurrent map downloads reached.");
		return Plugin_Handled;
	}
	
	char sArg1[64], sMap[64];
	GetCmdArg(1, sArg1, sizeof(sArg1));
	GetCmdArg(1, sMap, sizeof(sMap));
	
	if (FindStringInArray(g_aMapList, sArg1) == -1)
	{
		char sResponse[256];
		int iMapsFound;
		Format(sResponse, sizeof(sResponse), "[SM] Multiple maps found in search (specify or use exact name):\n");
		for (int i = 0; i < g_aMapList.Length; i++)
		{
			char sTemp[64];
			g_aMapList.GetString(i, sTemp, 64);
			if (StrContains(sTemp, sArg1, false) != -1)
			{
				iMapsFound++;
				Format(sResponse, sizeof(sResponse), "%s- %s\n", sResponse, sTemp);
				strcopy(sMap, sizeof(sMap), sTemp);
			}
		}
		if (iMapsFound == 0)
		{
			ReplyToCommand(iClient, "[SM] No maps found.");
			return Plugin_Handled;
		} else if (iMapsFound > 1)
		{
			ReplyToCommand(iClient, sResponse);
			return Plugin_Handled;
		}
	}

	for (int i = 0; i < MAX_MAP_DOWNLOAD; i++)
	{
		if (StrEqual(g_eMaps[i].sMapName, sMap) && g_eMaps[i].iStatus == MAP_DOWNLOADING)
		{
			ReplyToCommand(iClient, "[SM] Map download already in progress.");
			return Plugin_Handled;
		}
	}

	DownloadMap(sMap);

	ReplyToCommand(iClient, "[SM] Requested map download: %s (See sm_maplog)", sMap);
	return Plugin_Handled;
}

public Action Command_rmMap(int iClient, int args)
{
	if (args < 1)
	{
		ReplyToCommand(iClient, "[SM] Usage: sm_rmmap [map name]");
		return Plugin_Handled;
	}
	
	char sArg1[64], sMap[64];
	GetCmdArg(1, sArg1, sizeof(sArg1));
	GetCmdArg(1, sMap, sizeof(sMap));

	ArrayList MapArray = new ArrayList(256, 0);
	int aindex = 0;
	
	//allocate resources
	Handle dir = null;
	char buffer[PLATFORM_MAX_PATH + 1];
	FileType type;
	
	dir = OpenDirectory("maps/");
	if (dir == null)
	{
		LogError("[SM] Couldn't find the maps folder.");
		return Plugin_Handled;
	}
	
	while (ReadDirEntry(dir, buffer, sizeof(buffer), type))
	{
		int len = strlen(buffer);
		
		// Null-terminate if last char is newline
		if (buffer[len - 1] == '\n')
		{
			buffer[--len] = '\0';
		}
		
		// Remove spaces
		TrimString(buffer);
		
		// Skip empty, current, parent directory, and non-map directories
		if (!StrEqual(buffer, "", false) && !StrEqual(buffer, ".", false) && !StrEqual(buffer, "..", false) && !StrEqual(buffer, "soundcache", false) && !StrEqual(buffer, "cfg", false))
		{
			// Match files
			if (type == FileType_File)
			{
				if (StrContains(buffer, ".bsp", false) == strlen(buffer) - 4) {
					ReplaceString(buffer, sizeof(buffer), ".bsp", "", false);
					MapArray.PushString(buffer);
					//strcopy(MapArray[aindex], 1024, buffer);
					aindex++;
				}
			}
		}
	}
	
	if (FindStringInArray(MapArray, sArg1) == -1)
	{
		char sResponse[256];
		int iMapsFound;
		Format(sResponse, sizeof(sResponse), "[SM] Multiple maps found in search (specify or use exact name):\n");
		for (int i = 0; i < MapArray.Length; i++)
		{
			char sTemp[64];
			MapArray.GetString(i, sTemp, 64);
			if (StrContains(sTemp, sArg1, false) != -1)
			{
				iMapsFound++;
				Format(sResponse, sizeof(sResponse), "%s- %s\n", sResponse, sTemp);
				strcopy(sMap, sizeof(sMap), sTemp);
			}
		}
		if (iMapsFound == 0)
		{
			ReplyToCommand(iClient, "[SM] No maps found.");
			return Plugin_Handled;
		} else if (iMapsFound > 1)
		{
			ReplyToCommand(iClient, sResponse);
			return Plugin_Handled;
		}
	}

	char sDelString[128];
	Format(sDelString, sizeof(sDelString), "maps/%s.bsp", sMap);
	if (!DeleteFile(sDelString))
	{
		ReplyToCommand(iClient, "[SM] Unable to delete %s.bsp", sMap);
		return Plugin_Handled;
	}

	ReplyToCommand(iClient, "[SM] Deleted map: %s", sMap);
	LogMessage("[SM] Deleted map: %s", sMap);
	return Plugin_Handled;
}

public Action Command_searchMaps(int iClient, int args)
{
	if (args != 1)
	{
		ReplyToCommand(iClient, "[SM] Usage: sm_searchmaps [map name]");
		return Plugin_Handled;
	}
	
	char sArg1[64];
	GetCmdArg(1, sArg1, sizeof(sArg1));
	
	char sResponse[1000] = "";
	int iMapsFound;
	for (int i = 0; i < g_aMapList.Length; i++)
	{
		char sTemp[64];
		g_aMapList.GetString(i, sTemp, 64);
		if (StrContains(sTemp, sArg1, false) != -1)
		{
			iMapsFound++;
			Format(sResponse, sizeof(sResponse), "%s- %s\n", sResponse, sTemp);
		}
	}
	if (iMapsFound == 0)
	{
		ReplyToCommand(iClient, "[SM] No maps found.");
		return Plugin_Handled;
	} else {
		Format(sResponse, sizeof(sResponse), "[SM] Found %i of %i maps:\n%s", iMapsFound, g_aMapList.Length, sResponse);
		ReplyToCommand(iClient, sResponse);
		return Plugin_Handled;
	}
}

public Action Command_refreshMaps(int iClient, int args)
{
	GetMapList();
	ReplyToCommand(iClient, "[SM] Requested updated map list.");
	return Plugin_Handled;
}

public Action Command_mapLog(int iClient, int args)
{
	int iMapsOrdered[MAX_MAP_DOWNLOAD];

	for (int i = 0; i < MAX_MAP_DOWNLOAD; i++)
	{
		int iTempIndex = 0;
		for (int j = 0; j < MAX_MAP_DOWNLOAD; j++)
		{
			if (g_eMaps[j].iIndex > g_eMaps[i].iIndex)
			{
				iTempIndex++;
			}
		}
		iMapsOrdered[iTempIndex] = i;
	}

	char sResponse[4096];
	Format(sResponse, sizeof(sResponse), "Map Download Log:\n");

	for (int i = 0; i < MAX_MAP_DOWNLOAD; i++)
	{
		if (g_eMaps[iMapsOrdered[i]].iStatus != MAP_INVALID)
		{
			char sTime[32];
			FormatTime(sTime, sizeof(sTime), "[%m/%d %R]", g_eMaps[iMapsOrdered[i]].iTime);
			Format(sResponse, sizeof(sResponse), "%s- %s %s: ", sResponse, sTime, g_eMaps[iMapsOrdered[i]].sMapName);
			switch (g_eMaps[iMapsOrdered[i]].iStatus)
			{
				case MAP_DOWNLOADING:
				{
					float fProgress;
					SteamWorks_GetHTTPDownloadProgressPct(g_eMaps[iMapsOrdered[i]].hRequest, fProgress);
					int iBars = RoundFloat(fProgress / 10.0);
					Format(sResponse, sizeof(sResponse), "%s[", sResponse);
					for (int j = 0; j < 10; j++)
					{
						if (j >= iBars)
						{
							Format(sResponse, sizeof(sResponse), "%s ", sResponse);
						} else {
							Format(sResponse, sizeof(sResponse), "%s=", sResponse);
						}
					}
					Format(sResponse, sizeof(sResponse), "%s] %i\n", sResponse, RoundFloat(fProgress));
				}
				case MAP_SUCCESS:
				{
					Format(sResponse, sizeof(sResponse), "%sSucceeded.\n", sResponse);
				}
				case MAP_FAILED:
				{
					Format(sResponse, sizeof(sResponse), "%sFailed.\n", sResponse);
				}
			}
		}
	}

	ReplyToCommand(iClient, sResponse);
}

int GetNextMapIndex()
{
	int iMapsOrdered[MAX_MAP_DOWNLOAD] = { -1, ...};

	for (int i = 0; i < MAX_MAP_DOWNLOAD; i++)
	{
		int iTempIndex = 0;
		for (int j = 0; j < MAX_MAP_DOWNLOAD; j++)
		{
			if (g_eMaps[j].iIndex > g_eMaps[i].iIndex)
			{
				iTempIndex++;
			}
		}
		for (int j = iTempIndex; j < MAX_MAP_DOWNLOAD; j++)
		{
			if (iMapsOrdered[j] == -1)
			{
				iMapsOrdered[j] = i;
				break;
			}
		}	
	}

	for (int i = MAX_MAP_DOWNLOAD - 1; i > 0; i--)
	{
		if (iMapsOrdered[i] != -1)
		{
			if (g_eMaps[iMapsOrdered[i]].iStatus != MAP_DOWNLOADING)
			{
				return iMapsOrdered[i];
			}
		}
	}

	return -1;
}

void DownloadMap(char[] sMapName)
{
	char sURL[128], sFastDL[128];
	GetConVarString(cvar_FastDL, sFastDL, sizeof(sFastDL));
	Format(sURL, sizeof(sURL), "%s%s.bsp", sFastDL, sMapName);
	
	Handle HTTPRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	
	bool setnetwork = SteamWorks_SetHTTPRequestNetworkActivityTimeout(HTTPRequest, 20);
	bool setcontext = SteamWorks_SetHTTPRequestContextValue(HTTPRequest, g_iMapDownloadIndex);
	bool setcallback = SteamWorks_SetHTTPCallbacks(HTTPRequest, DownloadMapCallback);

	int iRawMapIndex = GetNextMapIndex();
	if (iRawMapIndex == -1)
	{
		CloseHandle(HTTPRequest);
		return;
	}

	strcopy(g_eMaps[iRawMapIndex].sMapName, 64, sMapName);
	g_eMaps[iRawMapIndex].iIndex = g_iMapDownloadIndex;
	g_eMaps[iRawMapIndex].iStatus = MAP_DOWNLOADING;
	g_eMaps[iRawMapIndex].iTime = GetTime();
	g_eMaps[iRawMapIndex].hRequest = INVALID_HANDLE;
	
	g_iMapDownloadIndex++;
	
	if (!setnetwork || !setcontext || !setcallback) {
		LogError("Error in setting request properties, cannot send request");
		CloseHandle(HTTPRequest);
		return;
	}
	
	//Initialize the request.
	bool sentrequest = SteamWorks_SendHTTPRequest(HTTPRequest);
	if (!sentrequest) {
		LogError("Error in sending request, cannot send request");
		CloseHandle(HTTPRequest);
		return;
	}

	g_eMaps[iRawMapIndex].hRequest = HTTPRequest;
}

public void DownloadMapCallback(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, int iMapIndex)
{
	int iRawIndex = -1;
	for (int i = 0; i < MAX_MAP_DOWNLOAD; i++)
	{
		if (g_eMaps[i].iIndex == iMapIndex)
		{
			iRawIndex = i;
		}
	}

	if (!bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK) {
		if (iRawIndex != -1)
		{
			g_eMaps[iRawIndex].hRequest = INVALID_HANDLE;
			g_eMaps[iRawIndex].iStatus = MAP_FAILED;
		}
		LogError("There was an error in the request");
		CloseHandle(hRequest);
		return;
	}
	
	int bodysize;
	bool bodyexists = SteamWorks_GetHTTPResponseBodySize(hRequest, bodysize);
	if (bodyexists == false) {
		if (iRawIndex != -1)
		{
			g_eMaps[iRawIndex].hRequest = INVALID_HANDLE;
			g_eMaps[iRawIndex].iStatus = MAP_FAILED;
		}
		LogError("Could not get body response size");
		CloseHandle(hRequest);
		return;
	}

	if (iRawIndex != -1)
	{
		char sFile[128];
		Format(sFile, sizeof(sFile), "/maps/%s.bsp", g_eMaps[iRawIndex].sMapName);
		SteamWorks_WriteHTTPResponseBodyToFile(hRequest, sFile);
	}

	LogMessage("Map download completed: %s", g_eMaps[iRawIndex].sMapName);
	
	CloseHandle(hRequest);
	if (iRawIndex != -1)
	{
		g_eMaps[iRawIndex].hRequest = INVALID_HANDLE;
		g_eMaps[iRawIndex].iStatus = MAP_SUCCESS;
	}
}

public Action Timer_updateMapList(Handle timer, int data)
{
	GetMapList();
}

void GetMapList()
{
	char sURL[64];
	GetConVarString(cvar_MapList, sURL, sizeof(sURL));
	
	Handle HTTPRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	
	bool setnetwork = SteamWorks_SetHTTPRequestNetworkActivityTimeout(HTTPRequest, 20);
	bool setcontext = SteamWorks_SetHTTPRequestContextValue(HTTPRequest, g_iMapDownloadIndex);
	bool setcallback = SteamWorks_SetHTTPCallbacks(HTTPRequest, GetMapListCallback);
	
	
	if (!setnetwork || !setcontext || !setcallback) {
		LogError("Error in setting request properties, cannot send request");
		CloseHandle(HTTPRequest);
		return;
	}
	
	//Initialize the request.
	bool sentrequest = SteamWorks_SendHTTPRequest(HTTPRequest);
	if (!sentrequest) {
		LogError("Error in sending request, cannot send request");
		CloseHandle(HTTPRequest);
		return;
	}
}

public void GetMapListCallback(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, int data)
{
	if (!bRequestSuccessful) {
		LogError("There was an error in the request");
		CloseHandle(hRequest);
		return;
	}
	
	int bodysize;
	bool bodyexists = SteamWorks_GetHTTPResponseBodySize(hRequest, bodysize);
	if (bodyexists == false) {
		LogError("Could not get body response size");
		CloseHandle(hRequest);
		return;
	}
	
	char bodybuffer[100000];
	if (bodysize > 100000) {
		LogError("The requested URL returned with more data than expected");
		CloseHandle(hRequest);
		return;
	}
	
	bool gotdata = SteamWorks_GetHTTPResponseBodyData(hRequest, bodybuffer, bodysize);
	if (gotdata == false) {
		LogError("Could not get body data or body data is blank");
		CloseHandle(hRequest);
		return;
	}
	
	CloseHandle(hRequest);

	g_aMapList.Clear();
	char sTempMapName[64];
	int iResult = 0;
	while (iResult != -1)
	{
		iResult = BreakString(bodybuffer, sTempMapName, sizeof(sTempMapName));
		if (strlen(sTempMapName) > 0)
		{
			g_aMapList.PushString(sTempMapName);
			ReplaceStringEx(bodybuffer, sizeof(bodybuffer), sTempMapName, "");
		}
	}
}