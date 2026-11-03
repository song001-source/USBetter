#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cfgmgr32.h>
#include <shellapi.h>
#include <sddl.h>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <fstream>
#include <sstream>
#include <thread>
#include <mutex>
#include <atomic>
#include <deque>
#include <stdexcept>
#include <cwctype>
using std::wstring;
static wstring directory,dataDir,session,pipeName;
static HANDLE changed,actions,quitEvent,cancelEvent;
static HWND window;
static std::atomic<bool> paused{false};
static std::mutex queueMutex;
static std::deque<wstring> queue;
static wstring Upper(wstring s){for(auto& c:s)c=towupper(c);return s;}
static wstring Quote(const wstring& s){
    wstring r=L"\"";size_t n=0;
    for(auto c:s){if(c==L'\\'){++n;continue;}r.append(c==L'"'?2*n+1:n,L'\\');n=0;r+=c;}
    r.append(n*2,L'\\');return r+L"\"";
}
static std::string Utf8(const wstring& s){
    int n=WideCharToMultiByte(CP_UTF8,0,s.data(),(int)s.size(),nullptr,0,nullptr,nullptr);
    std::string r(n,0);WideCharToMultiByte(CP_UTF8,0,s.data(),(int)s.size(),r.data(),n,nullptr,nullptr);return r;
}
static wstring Wide(const std::string& s){
    int n=MultiByteToWideChar(CP_UTF8,0,s.data(),(int)s.size(),nullptr,0);
    wstring r(n,0);MultiByteToWideChar(CP_UTF8,0,s.data(),(int)s.size(),r.data(),n);return r;
}
static std::string Read(const wstring& path){std::ifstream f(path,std::ios::binary);return std::string(std::istreambuf_iterator<char>(f),{});}
static void Atomic(const wstring& path,const std::string& content){
    auto tmp=path+L".tmp";{std::ofstream f(tmp,std::ios::binary|std::ios::trunc);f<<content;f.flush();if(!f)throw std::runtime_error("state write");}
    if(!MoveFileExW(tmp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("state replace");
}
static void Status(const wstring& text){Atomic(dataDir+L"\\status.txt",Utf8(text));}
struct Attachment {
    bool attempted=false;ULONGLONG missing=0;
    bool Update(bool present,ULONGLONG now){
        if(!present){if(!missing)missing=now?now:1;return false;}
        // ponytail: an 8s gap is a heuristic, not physical unplug proof. Fast
        // replug can be missed; a slow USB mode reset can look like new insertion.
        bool run=!attempted||(missing&&now>=missing&&now-missing>=8000);
        attempted=true;missing=0;return run;
    }
};
static std::set<wstring> Snapshot(){
    ULONG flags=CM_GETIDLIST_FILTER_ENUMERATOR|CM_GETIDLIST_FILTER_PRESENT;
    for(int i=0;i<4;++i){
        ULONG size=0;if(CM_Get_Device_ID_List_SizeW(&size,L"USB",flags)!=CR_SUCCESS)throw std::runtime_error("USB size");
        std::vector<wchar_t> ids(size+1);auto cr=CM_Get_Device_ID_ListW(L"USB",ids.data(),size,flags);
        if(cr==CR_BUFFER_SMALL)continue;if(cr!=CR_SUCCESS)throw std::runtime_error("USB list");
        std::set<wstring> result;
        for(auto p=ids.data();*p;p+=wcslen(p)+1){
            auto s=Upper(p);auto slash=s.find_last_of(L'\\');
            if(s.find(L"USB\\VID_")==0&&s.find(L"&MI_")==wstring::npos&&slash!=wstring::npos){
                auto key=s.substr(slash+1);if(key.find_first_of(L"|\r\n\t")==wstring::npos)result.insert(key);
            }
        }
        return result;
    }throw std::runtime_error("USB snapshot unstable");
}
static DWORD CALLBACK Notify(HCMNOTIFICATION,PVOID,CM_NOTIFY_ACTION,PCM_NOTIFY_EVENT_DATA event,DWORD){
    if(event->FilterType==CM_NOTIFY_FILTER_TYPE_DEVICEINSTANCE&&Upper(event->u.DeviceInstance.InstanceId).find(L"USB\\")==0)SetEvent(changed);
    return ERROR_SUCCESS;
}
static DWORD Worker(const wstring& action,const wstring& keys=L""){
    wchar_t system[MAX_PATH];GetSystemDirectoryW(system,MAX_PATH);
    wstring exe=wstring(system)+L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    auto command=Quote(exe)+L" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "+Quote(directory+L"\\scripts\\Helper.ps1")+
        L" -Action "+Quote(action)+L" -DataDir "+Quote(dataDir)+L" -SessionKey "+Quote(session)+L" -EligibleKeys "+Quote(keys)+L" -LauncherPid "+std::to_wstring(GetCurrentProcessId());
    HANDLE job=CreateJobObjectW(nullptr,nullptr);if(!job)throw std::runtime_error("job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};limit.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if(!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limit,sizeof(limit))){CloseHandle(job);throw std::runtime_error("job limits");}
    STARTUPINFOW si{};si.cb=sizeof(si);PROCESS_INFORMATION pi{};
    if(!CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW|CREATE_SUSPENDED,nullptr,directory.c_str(),&si,&pi)){
        CloseHandle(job);throw std::runtime_error("worker creation");
    }
    if(!AssignProcessToJobObject(job,pi.hProcess)){TerminateProcess(pi.hProcess,1);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);CloseHandle(job);throw std::runtime_error("job assignment");}
    ResumeThread(pi.hThread);CloseHandle(pi.hThread);
    HANDLE handles[]={pi.hProcess,quitEvent,cancelEvent};
    bool connection=action==L"Auto"||action==L"Connect"||action==L"Detect"||action==L"Choose"||action==L"Inspect";
    auto wait=WaitForMultipleObjects(connection?3:2,handles,FALSE,connection?125000:INFINITE);
    DWORD code=1;
    if(wait==WAIT_OBJECT_0)GetExitCodeProcess(pi.hProcess,&code);
    else {TerminateJobObject(job,1);WaitForSingleObject(pi.hProcess,5000);if(wait==WAIT_TIMEOUT)Status(L"连接失败：配置窗口已超时，请重新检测。");}
    CloseHandle(pi.hProcess);CloseHandle(job);return code;
}
static void Enqueue(const wstring& action){
    if(action==L"Pause"||action==L"Uninstall"){paused=true;try{Atomic(dataDir+L"\\paused","paused");}catch(...){}SetEvent(cancelEvent);}
    {std::lock_guard<std::mutex> lock(queueMutex);if(queue.size()<16)queue.push_back(action);}SetEvent(actions);
}
static void Engine(){
    try{
        std::map<wstring,Attachment> states;
        auto stateFile=dataDir+L"\\attachments-"+session+L".txt";
        std::istringstream saved(Read(stateFile));std::string line;
        while(std::getline(saved,line)){
            auto sep=line.find('\t');if(sep==std::string::npos)continue;
            try{states[Wide(line.substr(0,sep))]={true,std::stoull(line.substr(sep+1))};}catch(...){throw std::runtime_error("corrupt attachment state");}
        }
        auto save=[&](){std::string out;for(auto& item:states)out+=Utf8(item.first)+"\t"+std::to_string(item.second.missing)+"\n";Atomic(stateFile,out);};
        bool first=true;
        for(;;){
            HANDLE waits[]={quitEvent,actions,changed};
            auto wait=first?WAIT_OBJECT_0+2:WaitForMultipleObjects(3,waits,FALSE,INFINITE);first=false;
            if(wait==WAIT_OBJECT_0)break;
            if(wait==WAIT_OBJECT_0+1){
                for(;;){
                    wstring action;{std::lock_guard<std::mutex> lock(queueMutex);if(queue.empty())break;action=queue.front();queue.pop_front();}
                    ResetEvent(cancelEvent);
                    if(paused&&(action==L"Auto"||action==L"Connect"||action==L"Detect"||action==L"Choose"))continue;
                    if(action==L"Detect"||action==L"Connect"||action==L"Choose"){
                        auto roots=Snapshot();for(auto& key:roots)states[key].Update(true,GetTickCount64());save();
                    }
                    auto code=Worker(action);
                    if(action==L"Resume")paused=code!=0;
                    if(action==L"Uninstall"){PostMessageW(window,WM_CLOSE,0,0);return;}
                }
            }else{
                if(WaitForSingleObject(quitEvent,300)==WAIT_OBJECT_0)break;
                auto roots=Snapshot();auto now=GetTickCount64();wstring eligible;
                for(auto& item:states)if(!roots.count(item.first))item.second.Update(false,now);
                for(auto& key:roots)if(states[key].Update(true,now)){if(!eligible.empty())eligible+=L"|";eligible+=key;}
                save(); // Claim before spawning: a crash must not repeat this attachment.
                if(!paused){ResetEvent(cancelEvent);if(!paused)Worker(eligible.empty()?L"Inspect":L"Auto",eligible);}
            }
        }
    }catch(...){try{Status(L"连接失败：监听器状态或设备枚举异常，请查看诊断。");}catch(...){}PostMessageW(window,WM_CLOSE,1,0);}
}
static wstring Command(const wstring& arg){
    if(arg==L"--connect")return L"Connect";if(arg==L"--pause")return L"Pause";
    if(arg==L"--resume")return L"Resume";if(arg==L"--diagnose")return L"Diagnose";
    if(arg==L"--uninstall")return L"Uninstall";if(arg==L"--detect")return L"Detect";
    if(arg==L"--choose")return L"Choose";return L"";
}
static void PipeServer(){
    HANDLE token;PSECURITY_DESCRIPTOR sd=nullptr;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return;
    DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);std::vector<BYTE> bytes(size);
    if(!GetTokenInformation(token,TokenUser,bytes.data(),size,&size)){CloseHandle(token);return;}CloseHandle(token);
    LPWSTR sid=nullptr;if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid,&sid))return;
    wstring sddl=L"D:P(A;;GA;;;"+wstring(sid)+L")";LocalFree(sid);
    if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&sd,nullptr))return;
    SECURITY_ATTRIBUTES sa{sizeof(sa),sd,FALSE};
    HANDLE pipe=CreateNamedPipeW(pipeName.c_str(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,4096,4096,0,&sa);
    LocalFree(sd);if(pipe==INVALID_HANDLE_VALUE)return;
    auto transfer=[&](bool write,void* buffer,DWORD count,DWORD& transferred)->bool{
        OVERLAPPED op{};op.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        BOOL ok=write?WriteFile(pipe,buffer,count,&transferred,&op):ReadFile(pipe,buffer,count,&transferred,&op);
        if(!ok&&GetLastError()==ERROR_IO_PENDING){HANDLE waits[]={quitEvent,op.hEvent};auto w=WaitForMultipleObjects(2,waits,FALSE,3000);
            if(w==WAIT_OBJECT_0+1)ok=GetOverlappedResult(pipe,&op,&transferred,FALSE);
            else{CancelIoEx(pipe,&op);GetOverlappedResult(pipe,&op,&transferred,TRUE);ok=FALSE;}}
        CloseHandle(op.hEvent);return ok!=FALSE;
    };
    while(WaitForSingleObject(quitEvent,0)!=WAIT_OBJECT_0){
        OVERLAPPED op{};op.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);BOOL connected=ConnectNamedPipe(pipe,&op);DWORD error=GetLastError();
        if(!connected&&error==ERROR_IO_PENDING){HANDLE waits[]={quitEvent,op.hEvent};auto w=WaitForMultipleObjects(2,waits,FALSE,INFINITE);
            if(w==WAIT_OBJECT_0){CancelIoEx(pipe,&op);DWORD n;GetOverlappedResult(pipe,&op,&n,TRUE);CloseHandle(op.hEvent);break;}
            DWORD n;connected=GetOverlappedResult(pipe,&op,&n,FALSE);
        }else if(!connected&&error==ERROR_PIPE_CONNECTED)connected=TRUE;
        CloseHandle(op.hEvent);
        if(connected){
            char buffer[256];DWORD n=0;
            if(transfer(false,buffer,sizeof(buffer),n)){
                auto arg=Wide(std::string(buffer,n));std::string response;
                if(arg==L"--status")response=Read(dataDir+L"\\status.txt");
                else{auto action=Command(arg);if(!action.empty()){Enqueue(action);response="Accepted";}else response="Invalid command";}
                if(response.empty())response="等待手机";DWORD sent;
                // Wait for bounded acknowledgement before disconnecting; otherwise
                // Windows discards buffered reply bytes before the client reads them.
                if(transfer(true,response.data(),(DWORD)response.size(),sent)){char ack;DWORD received;transfer(false,&ack,1,received);}
            }
        }DisconnectNamedPipe(pipe);
    }CloseHandle(pipe);
}
static bool Client(const wstring& arg,bool show){
    if(!WaitNamedPipeW(pipeName.c_str(),2000))return false;
    HANDLE pipe=CreateFileW(pipeName.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,0,nullptr);
    if(pipe==INVALID_HANDLE_VALUE)return false;
    auto bytes=Utf8(arg);DWORD n;BOOL ok=WriteFile(pipe,bytes.data(),(DWORD)bytes.size(),&n,nullptr);
    std::string reply;
    auto deadline=GetTickCount64()+4000;
    while(ok&&GetTickCount64()<deadline){DWORD available=0;if(!PeekNamedPipe(pipe,nullptr,0,nullptr,&available,nullptr))break;
        if(available){char b[4096];if(ReadFile(pipe,b,sizeof(b),&n,nullptr)){reply.assign(b,n);char ack=1;WriteFile(pipe,&ack,1,&n,nullptr);}break;}Sleep(25);}
    CloseHandle(pipe);if(show){
        auto output=GetStdHandle(STD_OUTPUT_HANDLE);auto type=GetFileType(output);
        if(type==FILE_TYPE_PIPE||type==FILE_TYPE_DISK){DWORD written;auto text=reply+"\r\n";WriteFile(output,text.data(),(DWORD)text.size(),&written,nullptr);}
        else if(AttachConsole(ATTACH_PARENT_PROCESS)){DWORD written;auto text=Wide(reply)+L"\r\n";WriteConsoleW(GetStdHandle(STD_OUTPUT_HANDLE),text.data(),(DWORD)text.size(),&written,nullptr);}
        else MessageBoxW(nullptr,Wide(reply).c_str(),L"USB Tether Helper",MB_OK);
    }return !reply.empty();
}
static NOTIFYICONDATAW icon{};
static void TrayStatus(){auto status=Wide(Read(dataDir+L"\\status.txt"));if(status.empty())status=L"等待手机";
    wcsncpy_s(icon.szTip,status.c_str(),_TRUNCATE);icon.uFlags=NIF_TIP;Shell_NotifyIconW(NIM_MODIFY,&icon);}
static LRESULT CALLBACK WindowProc(HWND hwnd,UINT msg,WPARAM w,LPARAM l){
    if(msg==WM_APP+1&&(l==WM_RBUTTONUP||l==WM_LBUTTONUP)){
        auto menu=CreatePopupMenu();auto status=Wide(Read(dataDir+L"\\status.txt"));
        AppendMenuW(menu,MF_STRING|MF_GRAYED,0,status.empty()?L"等待手机":status.c_str());
        const wchar_t* labels[]={L"立即连接",L"重新检测",L"选择手机",L"暂停",L"恢复",L"诊断",L"设置 / 升级",L"卸载"};
        for(int i=0;i<8;++i)AppendMenuW(menu,MF_STRING,i+1,labels[i]);
        POINT point;GetCursorPos(&point);SetForegroundWindow(hwnd);
        int item=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY,point.x,point.y,0,hwnd,nullptr);DestroyMenu(menu);
        const wchar_t* cmds[]={L"Connect",L"Detect",L"Choose",L"Pause",L"Resume",L"Diagnose",L"Setup",L"Uninstall"};
        if(item>0&&item<=8){
            if(item==7){ // Run setup outside the resident job: it replaces this executable.
                ShellExecuteW(nullptr,L"open",(directory+L"\\UsbTetherHelper.exe").c_str(),L"--setup",directory.c_str(),SW_HIDE);
            }else Enqueue(cmds[item-1]);
        }return 0;
    }
    if(msg==WM_TIMER){TrayStatus();return 0;}
    if(msg==WM_CLOSE){SetEvent(quitEvent);SetEvent(cancelEvent);DestroyWindow(hwnd);return 0;}
    if(msg==WM_DESTROY){Shell_NotifyIconW(NIM_DELETE,&icon);PostQuitMessage((int)w);return 0;}
    return DefWindowProcW(hwnd,msg,w,l);
}
static int SelfTest(){
    auto require=[](bool ok){if(!ok)throw std::runtime_error("self test");};
    Attachment s;require(s.Update(true,100));require(!s.Update(true,200));require(!s.Update(false,1000));require(!s.Update(true,2000));
    require(!s.Update(false,3000));require(s.Update(true,12000));
    Attachment resumed{true,0};require(!resumed.Update(true,13000));
    resumed.Update(false,14000);Attachment restarted=resumed;require(!restarted.Update(true,15000));
    restarted.Update(false,16000);require(restarted.Update(true,25000));
    std::vector<wstring> samples={L"",L"中文 空格",L"a\"b",L"C:\\path with space\\",L"x\\\\\"y",L"|"};
    wstring cmd=L"test.exe";for(auto& sample:samples)cmd+=L" "+Quote(sample);
    int argc;auto argv=CommandLineToArgvW(cmd.c_str(),&argc);require(argv&&argc==(int)samples.size()+1);
    for(int i=1;i<argc;++i)require(samples[i-1]==argv[i]);LocalFree(argv);
    require(Command(L"--pause")==L"Pause"&&Command(L"--invalid").empty());return 0;
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int){
    try{
        int argc;auto argv=CommandLineToArgvW(GetCommandLineW(),&argc);if(!argv)return 2;
        std::vector<wstring> args(argv,argv+argc);LocalFree(argv);
        if(argc==2&&args[1]==L"--self-test")return SelfTest();
        wstring arg=argc==1?L"":args[1];if(argc>2)return 2;
        if(!arg.empty()&&arg!=L"--setup"&&arg!=L"--status"&&arg!=L"--resident"&&Command(arg).empty())return 2;
        wchar_t module[32768],local[32768];GetModuleFileNameW(nullptr,module,32768);GetEnvironmentVariableW(L"LOCALAPPDATA",local,32768);
        directory=module;directory.resize(directory.find_last_of(L'\\'));dataDir=wstring(local)+L"\\USB Tether Helper";CreateDirectoryW(dataDir.c_str(),nullptr);
        HANDLE token;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return 1;
        TOKEN_STATISTICS stats{};DWORD size;if(!GetTokenInformation(token,TokenStatistics,&stats,sizeof(stats),&size)){CloseHandle(token);return 1;}CloseHandle(token);
        session=std::to_wstring(stats.AuthenticationId.HighPart)+L"-"+std::to_wstring(stats.AuthenticationId.LowPart);
        pipeName=L"\\\\.\\pipe\\UsbTetherHelper-"+session;
        quitEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);cancelEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        if(arg==L"--setup"||(arg.empty()&&GetFileAttributesW((dataDir+L"\\config.json").c_str())==INVALID_FILE_ATTRIBUTES)){
            // The bootstrap exits so upgrades can replace the installed executable.
            wchar_t system[MAX_PATH];GetSystemDirectoryW(system,MAX_PATH);
            wstring exe=wstring(system)+L"\\WindowsPowerShell\\v1.0\\powershell.exe";
            wstring cmd=Quote(exe)+L" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "+Quote(directory+L"\\scripts\\Helper.ps1")+L" -Action Setup";
            STARTUPINFOW si{};si.cb=sizeof(si);PROCESS_INFORMATION pi{};
            if(!CreateProcessW(exe.c_str(),cmd.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,directory.c_str(),&si,&pi))return 1;
            CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return 0;
        }
        if(arg!=L"--resident"&&Client(arg.empty()?L"--status":arg,!arg.empty()))return 0;
        if(arg==L"--status"){
            MessageBoxW(nullptr,(L"监听器未运行。\n"+Wide(Read(dataDir+L"\\status.txt"))).c_str(),L"USB Tether Helper",MB_OK);return 1;
        }
        HANDLE lock=CreateFileW((dataDir+L"\\resident.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(lock==INVALID_HANDLE_VALUE)return GetLastError()==ERROR_SHARING_VIOLATION?0:1;
        paused=GetFileAttributesW((dataDir+L"\\paused").c_str())!=INVALID_FILE_ATTRIBUTES||arg==L"--pause"||arg==L"--uninstall";
        changed=CreateEventW(nullptr,FALSE,FALSE,nullptr);actions=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        WNDCLASSW wc{};wc.lpfnWndProc=WindowProc;wc.hInstance=instance;wc.lpszClassName=L"UsbTetherHelper";RegisterClassW(&wc);
        window=CreateWindowW(wc.lpszClassName,L"USB Tether Helper",0,0,0,0,0,nullptr,nullptr,instance,nullptr);
        if(!window||!changed||!actions)throw std::runtime_error("initialization");
        icon.cbSize=sizeof(icon);icon.hWnd=window;icon.uID=1;icon.uCallbackMessage=WM_APP+1;icon.hIcon=LoadIconW(nullptr,IDI_APPLICATION);
        icon.uFlags=NIF_MESSAGE|NIF_ICON|NIF_TIP;wcscpy_s(icon.szTip,L"USB Tether Helper");Shell_NotifyIconW(NIM_ADD,&icon);SetTimer(window,1,2000,nullptr);
        HCMNOTIFICATION notification=nullptr;CM_NOTIFY_FILTER filter{};filter.cbSize=sizeof(filter);filter.FilterType=CM_NOTIFY_FILTER_TYPE_DEVICEINSTANCE;filter.Flags=CM_NOTIFY_FILTER_FLAG_ALL_DEVICE_INSTANCES;
        if(CM_Register_Notification(&filter,nullptr,Notify,&notification)!=CR_SUCCESS)throw std::runtime_error("notification registration");
        if(paused)Status(L"已暂停");
        std::thread engine(Engine),pipe(PipeServer);
        if(!Command(arg).empty())Enqueue(Command(arg));
        MSG msg;while(GetMessageW(&msg,nullptr,0,0)>0){TranslateMessage(&msg);DispatchMessageW(&msg);}
        SetEvent(quitEvent);SetEvent(cancelEvent);engine.join();pipe.join();CM_Unregister_Notification(notification);
        CloseHandle(lock);CloseHandle(changed);CloseHandle(actions);CloseHandle(quitEvent);CloseHandle(cancelEvent);return (int)msg.wParam;
    }catch(...){return 1;}
}
