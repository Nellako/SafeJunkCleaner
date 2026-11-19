using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography.X509Certificates;
namespace SafeJunkCleaner.QuickClean;
internal static class Program {
    [STAThread] static int Main(string[] args){Console.OutputEncoding=new UTF8Encoding(false);try{var jobs=new Jobs(Store.Default,null);
        switch(args){case ["health"]:Print(new{Version=Store.Version,Backend="QuickClean",Framework=RuntimeInformation.FrameworkDescription,Protocol=1});return 0;
        case ["job",var op,var payload,var output]:return jobs.Job(op,payload,output);
        case ["query",var op]:using(var stream=Console.OpenStandardInput()){using var data=new MemoryStream();var buf=new byte[8192];int n;while((n=stream.Read(buf))!=0){Store.Require(data.Length+n<=16*1024*1024,"InputTooLarge");data.Write(buf,0,n);}Print(jobs.Query(op,Store.Obj(new UTF8Encoding(false,true).GetString(data.ToArray()).TrimStart('\uFEFF'))));return 0;}
        case ["maintenance-check"]:case ["maintenance"]:return Maintenance(args[0]=="maintenance");default:throw new InvalidDataException("UnsupportedArguments");}
        }catch(System.ComponentModel.Win32Exception e) when(e.NativeErrorCode==1223){return 1223;}catch(Exception e){Console.Error.WriteLine(e.Message);return 2;}}
    static void Print(object o)=>Console.WriteLine(JsonSerializer.Serialize(o));
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct FileInfoTrust{public uint cb;[MarshalAs(UnmanagedType.LPWStr)]public string path;public IntPtr handle,known;}
    [StructLayout(LayoutKind.Sequential)]struct Trust{public uint cb;public IntPtr callback,client;public uint ui,revocation,choice;public IntPtr file;public uint stateAction;public IntPtr state,url;public uint flags,context;public IntPtr signature;}
    [DllImport("wintrust.dll",ExactSpelling=true)]static extern int WinVerifyTrust(IntPtr window,ref Guid action,ref Trust data);
    [DllImport("wintrust.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CryptCATAdminAcquireContext2(out IntPtr h,IntPtr subsystem,string algorithm,IntPtr policy,uint flags);
    [DllImport("wintrust.dll",SetLastError=true)]static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr admin,IntPtr file,ref uint length,[Out]byte[]? hash,uint flags);
    [DllImport("wintrust.dll",SetLastError=true)]static extern IntPtr CryptCATAdminEnumCatalogFromHash(IntPtr admin,byte[] hash,uint size,uint flags,IntPtr previous);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct CatalogPath{public uint cb;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)]public string path;}
    [DllImport("wintrust.dll",CharSet=CharSet.Unicode)]static extern bool CryptCATCatalogInfoFromContext(IntPtr cat,ref CatalogPath info,uint flags);
    [DllImport("wintrust.dll")]static extern bool CryptCATAdminReleaseContext(IntPtr admin,uint flags);
    [DllImport("wintrust.dll")]static extern bool CryptCATAdminReleaseCatalogContext(IntPtr admin,IntPtr cat,uint flags);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct CatalogTrust{public uint cb,version;[MarshalAs(UnmanagedType.LPWStr)]public string cat,tag,path;public IntPtr handle,hash;public uint length;public IntPtr context,admin;}
    static string VerifyCatalog(string path,FileStream stream){foreach(string alg in new[]{"SHA256","SHA1"}){
        if(!CryptCATAdminAcquireContext2(out var admin,0,alg,0,0))continue;IntPtr cat=0;try{uint size=0;var fd=stream.SafeFileHandle.DangerousGetHandle();stream.Position=0;CryptCATAdminCalcHashFromFileHandle2(admin,fd,ref size,null,0);if(size==0||size>128)continue;byte[] hash=new byte[size];if(!CryptCATAdminCalcHashFromFileHandle2(admin,fd,ref size,hash,0))continue;cat=CryptCATAdminEnumCatalogFromHash(admin,hash,size,0,0);if(cat==0)continue;CatalogPath catalog=new(){cb=(uint)Marshal.SizeOf<CatalogPath>(),path=""};if(!CryptCATCatalogInfoFromContext(cat,ref catalog,0))continue;var m=new CatalogTrust{cb=(uint)Marshal.SizeOf<CatalogTrust>(),cat=catalog.path,tag=Convert.ToHexString(hash),path=path,handle=fd,admin=admin};var ptr=Marshal.AllocHGlobal((int)m.cb);Marshal.StructureToPtr(m,ptr,false);try{var trust=new Trust{cb=(uint)Marshal.SizeOf<Trust>(),ui=2,choice=2,file=ptr,flags=0x1000};var action=new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");if(WinVerifyTrust(-1,ref action,ref trust)==0)return catalog.path;}finally{Marshal.DestroyStructure<CatalogTrust>(ptr);Marshal.FreeHGlobal(ptr);}}finally{if(cat!=0)CryptCATAdminReleaseCatalogContext(admin,cat,0);CryptCATAdminReleaseContext(admin,0);}}throw new InvalidDataException("DismSignatureInvalid");}
    static int Maintenance(bool start){string path=Path.Combine(Environment.SystemDirectory,"dism.exe");Store.Plain(path);using var held=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.Read);var file=new FileInfoTrust{cb=(uint)Marshal.SizeOf<FileInfoTrust>(),path=path,handle=held.SafeFileHandle.DangerousGetHandle()};var ptr=Marshal.AllocHGlobal((int)file.cb);Marshal.StructureToPtr(file,ptr,false);try{var trust=new Trust{cb=(uint)Marshal.SizeOf<Trust>(),ui=2,choice=1,file=ptr,flags=0x1000};var action=new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");string signed=WinVerifyTrust(-1,ref action,ref trust)==0?path:VerifyCatalog(path,held);
#pragma warning disable SYSLIB0057
        using var signer=new X509Certificate2(X509Certificate.CreateFromSignedFile(signed));
#pragma warning restore SYSLIB0057
        Store.Require(signer.Subject.Split(',').Any(s=>s.Trim()=="O=Microsoft Corporation"),"DismSignerInvalid");}finally{Marshal.DestroyStructure<FileInfoTrust>(ptr);Marshal.FreeHGlobal(ptr);}const string arguments="/Online /Cleanup-Image /StartComponentCleanup";if(!start){Print(new{Status="Ready",FileName=path,Arguments=arguments,Elevation="DismOnly",Started=false});return 0;}using var p=Process.Start(new ProcessStartInfo(path,arguments){UseShellExecute=true,Verb="runas",WorkingDirectory=Environment.SystemDirectory})!;p.WaitForExit();return p.ExitCode;}
}
