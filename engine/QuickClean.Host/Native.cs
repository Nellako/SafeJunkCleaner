#nullable disable
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace SjcV3 {
 public sealed class Identity { public string Key; public uint Links; public uint Attributes; }
 public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct Info {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
   public System.Runtime.InteropServices.ComTypes.FILETIME Access; public System.Runtime.InteropServices.ComTypes.FILETIME Write;
   public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
  static Info Read(SafeFileHandle h) {
   if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
   Info i; if(!GetFileInformationByHandle(h,out i)) throw new Win32Exception(Marshal.GetLastWin32Error()); return i;
  }
  static string Key(Info i) { return String.Format("{0:X8}:{1:X8}{2:X8}:{3:X8}{4:X8}",i.Volume,i.IndexHigh,i.IndexLow,i.Creation.dwHighDateTime,i.Creation.dwLowDateTime); }
  public static Identity ReadIdentity(string path) {
   using (SafeFileHandle h = CreateFile(LongPath(path), 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
    Info i=Read(h); return new Identity { Key=Key(i), Links=i.Links, Attributes=i.Attributes };
   }
  }
  static string LongPath(string path) {
   if(path.Length<3 || path[1]!=':' || path[2]!='\\' || path.IndexOf(':',2)>=0 || !String.Equals(Path.GetFullPath(path),path,StringComparison.OrdinalIgnoreCase)) throw new IOException("Noncanonical local path");
   return @"\\?\"+path;
  }
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int infoClass,ref byte disposition,uint size);
  // All ancestor handles deny delete sharing until the disposition is applied to
  // the SAME exclusive file handle whose identity, length and mtime were checked.
  public static void DeleteSnapshot(string path,string expected,long bytes,long ticks) {
   var held=new Stack<SafeFileHandle>(); var parents=new Stack<string>();
   for(var d=Directory.GetParent(path); d!=null; d=d.Parent) parents.Push(d.FullName);
   try {
    foreach(string parent in parents) {
     var dir=CreateFile(LongPath(parent),0,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero); held.Push(dir);
     if((Read(dir).Attributes & 0x410)!=0x10) throw new IOException("Unsafe ancestor");
    }
    using(var h=CreateFile(LongPath(path),0x10080,0,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
     var i=Read(h); long ft=((long)(uint)i.Write.dwHighDateTime<<32)|(uint)i.Write.dwLowDateTime;
     if(i.Links!=1 || (i.Attributes & 0x1411)!=0 || Key(i)!=expected || (((long)i.SizeHigh<<32)|i.SizeLow)!=bytes || DateTime.FromFileTimeUtc(ft).Ticks!=ticks) throw new IOException("File changed before delete");
     byte yes=1; if(!SetFileInformationByHandle(h,4,ref yes,1)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
   } finally {while(held.Count!=0) held.Pop().Dispose();}
  }
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint SHEmptyRecycleBin(IntPtr hwnd, string root, uint flags);
 }
 public sealed class RunResult {
  public long Reviewed, Deleted, ProcessedBytes, Skipped, ErrorCount; public string Status="Failed";
  public readonly List<string> Errors=new List<string>();
 }
 // Windows Shell confirms the recycled IShellItem via PostDeleteItem. A request
 // for a permanent delete (even as a Shell fallback) is vetoed at PreDeleteItem.
 [ComImport,Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IShellItem { void BindToHandler(IntPtr ctx,ref Guid handler,ref Guid iid,out IntPtr p);void GetParent(out IShellItem p);void GetDisplayName(uint kind,out IntPtr p);void GetAttributes(uint mask,out uint attrs);void Compare(IShellItem item,uint hint,out int order); }
 [ComImport,Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 interface IFileOperation {
  void Advise(ISink sink,out uint cookie);void Unadvise(uint cookie);void SetOperationFlags(uint flags);
  void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)]string message);void SetProgressDialog(IntPtr dlg);void SetProperties(IntPtr props);void SetOwnerWindow(IntPtr hwnd);
  void ApplyPropertiesToItem(IShellItem item);void ApplyPropertiesToItems(IntPtr items);void RenameItem(IShellItem item,string name,ISink sink);void RenameItems(IntPtr items,string name);
  void MoveItem(IShellItem item,IShellItem dest,string name,ISink sink);void MoveItems(IntPtr items,IShellItem dest);void CopyItem(IShellItem item,IShellItem dest,string name,ISink sink);void CopyItems(IntPtr items,IShellItem dest);
  void DeleteItem(IShellItem item,ISink sink);void DeleteItems(IntPtr items);void NewItem(IShellItem dest,uint attrs,string name,string template,ISink sink);
  [PreserveSig]int PerformOperations();void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)]out bool aborted);
 }
 [ComVisible(true),Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface ISink {
  [PreserveSig]int StartOperations();[PreserveSig]int FinishOperations(int hr);
  [PreserveSig]int PreRenameItem(uint f,IShellItem i,string n);[PreserveSig]int PostRenameItem(uint f,IShellItem i,string n,int hr,IShellItem created);
  [PreserveSig]int PreMoveItem(uint f,IShellItem i,IShellItem d,string n);[PreserveSig]int PostMoveItem(uint f,IShellItem i,IShellItem d,string n,int hr,IShellItem created);
  [PreserveSig]int PreCopyItem(uint f,IShellItem i,IShellItem d,string n);[PreserveSig]int PostCopyItem(uint f,IShellItem i,IShellItem d,string n,int hr,IShellItem created);
  [PreserveSig]int PreDeleteItem(uint f,IShellItem i);[PreserveSig]int PostDeleteItem(uint f,IShellItem i,int hr,IShellItem created);
  [PreserveSig]int PreNewItem(uint f,IShellItem d,string n);[PreserveSig]int PostNewItem(uint f,IShellItem d,string n,string t,uint a,int hr,IShellItem created);
  [PreserveSig]int UpdateProgress(uint t,uint d);[PreserveSig]int ResetTimer();[PreserveSig]int PauseTimer();[PreserveSig]int ResumeTimer();
 }
 [ComVisible(true),ClassInterface(ClassInterfaceType.None)]public sealed class RecycleSink:ISink {
  const int Abort=unchecked((int)0x80004004);readonly string path,key;readonly long size,ticks;bool pre,post;
  RecycleSink(string p,string k,long b,long t){path=p;key=k;size=b;ticks=t;}
  [DllImport("shell32.dll",CharSet=CharSet.Unicode,PreserveSig=true)]static extern int SHCreateItemFromParsingName(string path,IntPtr ctx,ref Guid iid,out IShellItem item);
  public static void Move(string path,string key,long size,long ticks){
   if(Thread.CurrentThread.GetApartmentState()!=ApartmentState.STA)throw new IOException("Recycle requires STA");
   IFileOperation op=null;IShellItem item=null;var sink=new RecycleSink(path,key,size,ticks);
   try{op=(IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3ad05575-8857-4850-9277-11b85bdb8e09"),true));var iid=typeof(IShellItem).GUID;
    Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path,IntPtr.Zero,ref iid,out item));op.SetOperationFlags(0x00080000|0x00100000|0x0400|4|0x2000|0x1000);
    op.DeleteItem(item,sink);int hr=op.PerformOperations();bool aborted;op.GetAnyOperationsAborted(out aborted);
    if(hr<0||aborted||!sink.pre||!sink.post)throw new IOException("Shell did not confirm recycle; do not retry");
   }finally{GC.KeepAlive(sink);if(item!=null)Marshal.FinalReleaseComObject(item);if(op!=null)Marshal.FinalReleaseComObject(op);}
  }
  public int PreDeleteItem(uint flags,IShellItem item){IntPtr ptr=IntPtr.Zero;try{
   if(pre||(flags&0x80)==0)return Abort;item.GetDisplayName(0x80058000,out ptr);
   if(!String.Equals(Marshal.PtrToStringUni(ptr),path,StringComparison.OrdinalIgnoreCase))return Abort;
   for(var d=Directory.GetParent(path);d!=null;d=d.Parent)if((d.Attributes&FileAttributes.ReparsePoint)!=0)return Abort;
   var id=Native.ReadIdentity(path);var f=new FileInfo(path);if(id.Key!=key||id.Links!=1||(id.Attributes&0x1411)!=0||f.Length!=size||f.LastWriteTimeUtc.Ticks!=ticks)return Abort;
   pre=true;return 0;}catch{return Abort;}finally{if(ptr!=IntPtr.Zero)Marshal.FreeCoTaskMem(ptr);} }
  public int PostDeleteItem(uint flags,IShellItem item,int hr,IShellItem created){post=pre&&hr>=0&&created!=null&&(flags&0x80)!=0;return post?0:Abort;}
  public int StartOperations(){return 0;}public int FinishOperations(int hr){return 0;}
  public int PreRenameItem(uint f,IShellItem i,string n){return Abort;}public int PostRenameItem(uint f,IShellItem i,string n,int hr,IShellItem c){return Abort;}
  public int PreMoveItem(uint f,IShellItem i,IShellItem d,string n){return Abort;}public int PostMoveItem(uint f,IShellItem i,IShellItem d,string n,int hr,IShellItem c){return Abort;}
  public int PreCopyItem(uint f,IShellItem i,IShellItem d,string n){return Abort;}public int PostCopyItem(uint f,IShellItem i,IShellItem d,string n,int hr,IShellItem c){return Abort;}
  public int PreNewItem(uint f,IShellItem d,string n){return Abort;}public int PostNewItem(uint f,IShellItem d,string n,string t,uint a,int hr,IShellItem c){return Abort;}
  public int UpdateProgress(uint t,uint d){return 0;}public int ResetTimer(){return 0;}public int PauseTimer(){return 0;}public int ResumeTimer(){return 0;}
 }
 public static class QuickClean {
  public static bool Walk(string root,Func<bool> cancelled,Func<string,bool> safe,Action<FileInfo> accept,Action<string> warn){
   var queue=new Queue<string>();queue.Enqueue(root);string prefix=root.TrimEnd('\\')+"\\";
   while(queue.Count!=0){if(cancelled())return false;string dir=queue.Dequeue();
    try{if(!safe(dir))throw new IOException("目录或祖先包含链接/不可读。");
     foreach(var item in new DirectoryInfo(dir).EnumerateFileSystemInfos()){
      if(cancelled())return false;
      try{if(!item.FullName.StartsWith(prefix,StringComparison.OrdinalIgnoreCase) || (item.Attributes & (FileAttributes.ReparsePoint|FileAttributes.Offline))!=0)throw new IOException("跳过不受支持的条目。");
       var child=item as DirectoryInfo;if(child!=null){queue.Enqueue(child.FullName);continue;}
       var f=item as FileInfo;if(f!=null)accept(f);
      }catch(Exception ex){warn(item.FullName+": "+ex.GetBaseException().Message);}
     }
    }catch(Exception ex){warn(dir+": "+ex.GetBaseException().Message);}
   }return true;
  }
  // Never accept an unvalidated path list from the worker request. The caller
  // holds the authenticated plan stream read-locked and supplies its policy adapter.
  public static RunResult Execute(Stream plan,string task,long expectedCount, long expectedBytes,
    string[] excluded,Func<string,string[]> validate,Func<bool> cancelled, Action<string[]> apply,
    Action<long,long> progress,Action beforeClaim) {
   var r=new RunResult(); var ids=new HashSet<string>(StringComparer.Ordinal); var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   var keep=new HashSet<string>(excluded,StringComparer.Ordinal); if(keep.Count!=excluded.Length)throw new IOException("Duplicate exclusion");
   long bytes=0,count=0; plan.Position=0;
   using(var reader=Reader(plan)){string line;while((line=reader.ReadLine())!=null){
    if(cancelled()){r.Status="Cancelled";return r;} var x=validate(line);
    if(x.Length!=6 || !ids.Add(x[0]) || !paths.Add(x[2]))throw new IOException("Duplicate or invalid candidate");
    checked{bytes+=long.Parse(x[3],System.Globalization.CultureInfo.InvariantCulture);count++;}
   }}
   if(count!=expectedCount || bytes!=expectedBytes || !keep.IsSubsetOf(ids))throw new IOException("Candidate totals or exclusions do not match sealed plan");
   beforeClaim(); if(cancelled()){r.Status="Cancelled";return r;}
   using(var claim=new FileStream(Path.Combine(task,"clean.claimed"),FileMode.CreateNew,FileAccess.Write,FileShare.None)) {claim.WriteByte(1);claim.Flush(true);}
   plan.Position=0; using(var journal=new FileStream(Path.Combine(task,"execution.ledger"),FileMode.CreateNew,FileAccess.Write,FileShare.Read))
   using(var reader=Reader(plan)){string line;while((line=reader.ReadLine())!=null){
    if(cancelled()){r.Status="Cancelled";return r;} var x=validate(line);r.Reviewed++;
    if(keep.Contains(x[0])){r.Skipped++;continue;}
    Record(journal,"intent",x[0]);
    try{apply(x);}catch(Exception err){r.Skipped++;r.ErrorCount++;if(r.Errors.Count<200)r.Errors.Add(x[2]+": "+err.GetBaseException().Message);Record(journal,"not-confirmed",x[0]);continue;}
    Record(journal,"processed",x[0]);r.Deleted++;r.ProcessedBytes+=long.Parse(x[3],System.Globalization.CultureInfo.InvariantCulture);
    progress(r.Reviewed,count);
   }
   r.Status=r.ErrorCount==0?"Success":"Partial";Record(journal,"end",r.Status);return r;}
  }
  static void Record(FileStream f,string action,string value){var b=Encoding.UTF8.GetBytes(action+" "+value+"\n");f.Write(b,0,b.Length);f.Flush(true);}
  static StreamReader Reader(Stream p){return new StreamReader(p,new UTF8Encoding(false,true),true,65536,true);}
  public static long[] PageOffsets(Stream p,CancellationToken token){
   p.Position=0;long pos=0,start=0;int n;var buf=new byte[65536];var offsets=new List<long>();
   while((n=p.Read(buf,0,buf.Length))>0){token.ThrowIfCancellationRequested();for(int i=0;i<n;i++)if(buf[i]==10){offsets.Add(start);start=pos+i+1;}pos+=n;}
   if(start<pos)offsets.Add(start);return offsets.ToArray();
  }
 }
}
