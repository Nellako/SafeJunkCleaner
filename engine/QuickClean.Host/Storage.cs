using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SafeJunkCleaner.QuickClean;

internal static class Store
{
    public const string Version = "0.17.0";
    public static string Default => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"SafeJunkCleaner\v3");
    public static void Require(bool ok, string why) { if (!ok) throw new InvalidDataException(why); }
    public static string Canon(string path) {
        Require(Regex.IsMatch(path,@"^[A-Za-z]:\\") && !path[2..].Contains(':') && !path.Any(char.IsControl) && path == Path.GetFullPath(path) && !path[3..].Split('\\').Any(s=>s.EndsWith('.')||s.EndsWith(' ')||Regex.IsMatch(s,@"^(CON|AUX|NUL|PRN|LPT[0-9]|COM[0-9])(\.|$)",RegexOptions.IgnoreCase)),"NonCanonicalPath");
        Require(new DriveInfo(path[..3]).DriveType is DriveType.Fixed or DriveType.Removable,"UnsupportedVolume");return path;
    }
    public static bool Within(string path,string root)=>path.StartsWith(root.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase);
    public static void Plain(string path,bool missing=false){Canon(path);for(string? p=path;p!=null;p=Path.GetDirectoryName(p)){
        try{Require((File.GetAttributes(p)&(FileAttributes.ReparsePoint|FileAttributes.Offline))==0,"UnsafeAncestor");}
        catch(FileNotFoundException) when(missing){}catch(DirectoryNotFoundException) when(missing){}
    }}
    public static void Private(string path){Plain(path);var acl=new DirectoryInfo(path).GetAccessControl();var sid=WindowsIdentity.GetCurrent().User!;
        Require(acl.GetOwner(typeof(SecurityIdentifier))!.Equals(sid)&&acl.AreAccessRulesProtected,"PrivateDirectoryRequired");
        foreach(FileSystemAccessRule rule in acl.GetAccessRules(true,true,typeof(SecurityIdentifier))) Require(rule.AccessControlType!=AccessControlType.Allow||rule.IdentityReference.Equals(sid)||rule.IdentityReference.Value=="S-1-5-18","UnexpectedDirectoryGrant");}
    public static void PlainFile(string p){Plain(p);var i=SjcV3.Native.ReadIdentity(p);Require(i.Links==1&&(i.Attributes&0x1410)==0,"UnsafeFile");}
    public static string Text(string p,int limit=4*1024*1024){PlainFile(p);using var f=new FileStream(p,FileMode.Open,FileAccess.Read,FileShare.Read);Require(f.Length<=limit,"FileTooLarge");using var r=new StreamReader(f,new UTF8Encoding(false,true),true);return r.ReadToEnd();}
    public static void Write(string p,string text,bool replace=false){Plain(Path.GetDirectoryName(p)!);if(File.Exists(p))PlainFile(p);string t=Path.Combine(Path.GetDirectoryName(p)!,".qc-"+Guid.NewGuid().ToString("N"));
        using(var f=new FileStream(t,FileMode.CreateNew,FileAccess.Write,FileShare.None)){f.Write(Encoding.UTF8.GetBytes(text));f.Flush(true);}File.Move(t,p,replace);}
    public static JsonElement Obj(string text) {using var d=JsonDocument.Parse(text,new(){MaxDepth=32});var j=d.RootElement;Require(j.ValueKind==JsonValueKind.Object,"ExpectedObject");var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);foreach(var p in j.EnumerateObject())Require(names.Add(p.Name),"DuplicateField");return j.Clone();}
    public static string Hash(string s)=>Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(s)));
    public static string Str(this JsonElement j,string name)=>j.GetProperty(name).GetString()??throw new InvalidDataException("Missing "+name);
    public static void Fields(this JsonElement j,params string[] fields){Require(j.EnumerateObject().Select(x=>x.Name).ToHashSet().SetEquals(fields),"UnexpectedFields");}
    [StructLayout(LayoutKind.Sequential)]struct Blob{public int Size;public IntPtr Pointer;}
    [DllImport("crypt32.dll",SetLastError=true,CharSet=CharSet.Unicode)]static extern bool CryptProtectData(ref Blob data,string? name,ref Blob entropy,IntPtr zero,IntPtr prompt,int flags,out Blob result);
    [DllImport("crypt32.dll",SetLastError=true)]static extern bool CryptUnprotectData(ref Blob data,IntPtr name,ref Blob entropy,IntPtr zero,IntPtr prompt,int flags,out Blob result);
    [DllImport("kernel32.dll")]static extern IntPtr LocalFree(IntPtr ptr);
    static byte[] Crypt(byte[] input,bool protect){byte[] salt="SafeJunkCleaner-v3-seal"u8.ToArray();var a=GCHandle.Alloc(input,GCHandleType.Pinned);var b=GCHandle.Alloc(salt,GCHandleType.Pinned);Blob result=default;
        try{var data=new Blob{Size=input.Length,Pointer=a.AddrOfPinnedObject()};var entropy=new Blob{Size=salt.Length,Pointer=b.AddrOfPinnedObject()};bool ok=protect?CryptProtectData(ref data,null,ref entropy,0,0,1,out result):CryptUnprotectData(ref data,0,ref entropy,0,0,1,out result);if(!ok)throw new Win32Exception();var bytes=new byte[result.Size];Marshal.Copy(result.Pointer,bytes,0,bytes.Length);return bytes;}finally{if(result.Pointer!=0)LocalFree(result.Pointer);a.Free();b.Free();}}
    public static string Seal(object obj)=>Convert.ToBase64String(Crypt(JsonSerializer.SerializeToUtf8Bytes(obj),true));
    public static JsonElement Open(string p)=>Obj(Encoding.UTF8.GetString(Crypt(Convert.FromBase64String(Text(p)),false)));
}
