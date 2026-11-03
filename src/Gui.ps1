# WPF desktop presentation. File operations stay in the engine or a background runspace.
function Initialize-SjcDesktop {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
}
function Format-SjcGuiSize {
    param([double]$Bytes)
    foreach($unit in @('B','KB','MB','GB','TB')) {
        if($Bytes -lt 1024 -or $unit -eq 'TB') { return ('{0:N2} {1}' -f $Bytes,$unit) }
        $Bytes /= 1024
    }
}
function Get-SjcGuiValue {
    param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    if($Object.PSObject.Properties[$Name]){return $Object.$Name};return $Default
}
function Get-SjcGuiLaunchSpec {
    param([string]$Mode,[string]$PayloadPath,[string]$OutputPath)
    $entry=Get-Variable -Scope Script -Name SjcEntryPath -ValueOnly -ErrorAction SilentlyContinue
    $packaged=Get-Variable -Scope Script -Name SjcIsPackaged -ValueOnly -ErrorAction SilentlyContinue
    if(-not $entry -or -not [IO.File]::Exists($entry)){throw '找不到程序入口，请从 Main.ps1 或交付 EXE 启动。'}
    foreach($path in @($entry,$PayloadPath,$OutputPath)){if($path.Contains('"')){throw '启动路径含无效字符。'}}
    $arguments='-WorkerMode '+$Mode+' -PayloadPath "'+$PayloadPath+'" -OutputPath "'+$OutputPath+'"'
    if($packaged){return @{FileName=$entry;Arguments=('-end '+$arguments)}}
    if([IO.Path]::GetFileName($entry) -in @('Gui.ps1','Core.ps1','Rules.ps1','Worker.ps1')){throw '不能从模块文件启动后台任务。'}
    return @{FileName=(Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -ExecutionPolicy Bypass -STA -File "'+$entry+'" '+$arguments)}
}
# 操作图标统一使用 Windows 系统字体 Segoe MDL2 Assets（不随应用分发）。语义名到码位的唯一映射，只保留实际使用的图标。
function Get-SjcGuiGlyphMap {
    return @{
        Scan='E721';Clean='E74D';Cancel='E711';EmptyRecycle='E74D';Previous='E76B';Next='E76C'
        Keep='E72E';Unkeep='E785';Copy='E8C8';Export='EDE1';CheckPage='E73A';ClearSelection='E8E6'
        OpenLog='E8E5';Details='E946';RemoveRecord='E74D';Logs='E81C';Settings='E713';Reset='E72C'
        ChevronDown='E70D';ChevronUp='E70E';Warning='E7BA';Shield='EA18';Files='E8A5'
    }
}
function Get-SjcGuiGlyph {
    param([Parameter(Mandatory=$true)][string]$Name)
    $map=Get-SjcGuiGlyphMap
    if(-not $map.ContainsKey($Name)){throw ('未定义的操作图标：'+$Name)}
    return [string][char][Convert]::ToInt32($map[$Name],16)
}
function Expand-SjcGuiGlyphs {
    param([Parameter(Mandatory=$true)][string]$Xaml)
    $map=Get-SjcGuiGlyphMap
    foreach($match in [regex]::Matches($Xaml,'\{G:([A-Za-z]+)\}')){if(-not $map.ContainsKey($match.Groups[1].Value)){throw ('未定义的操作图标：'+$match.Groups[1].Value)}}
    $result=$Xaml
    foreach($key in $map.Keys){$result=$result.Replace('{G:'+$key+'}','&#x'+$map[$key]+';')}
    return $result
}
# 应用图标：打包 EXE 由 build 注入 $script:SjcEmbeddedIconBase64（完整 ICO）；源码运行回退 assets\app.ico。不从 EXE 提取，避免单文件无图或错图。
function Get-SjcGuiIconPath {
    $entry=Get-Variable -Scope Script -Name SjcEntryPath -ValueOnly -ErrorAction SilentlyContinue
    $packaged=Get-Variable -Scope Script -Name SjcIsPackaged -ValueOnly -ErrorAction SilentlyContinue
    if(-not $entry -or $packaged){return $null}
    $sourceDirectory=[IO.Path]::GetDirectoryName($entry)
    if(-not $sourceDirectory){return $null}
    $candidate=Join-Path ([IO.Path]::GetDirectoryName($sourceDirectory)) 'assets\app.ico'
    if([IO.File]::Exists($candidate)){return $candidate}
    return $null
}
function ConvertFrom-SjcGuiIconStream {
    param([IO.Stream]$Stream)
    $decoder=[Windows.Media.Imaging.IconBitmapDecoder]::new($Stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $frames=@($decoder.Frames|Sort-Object PixelWidth)
    if($frames.Count -eq 0){throw '图标没有可用帧。'}
    $image=$frames[-1]
    if($image.CanFreeze){$image.Freeze()}
    return $image
}
function Get-SjcGuiAppIcon {
    # Window 与 Brand 使用同一帧同一来源；优先 build 注入的完整 ICO，源码运行回退 assets\app.ico。
    $result=@{Window=$null;Brand=$null;Source=''}
    $embedded=Get-Variable -Scope Script -Name SjcEmbeddedIconBase64 -ValueOnly -ErrorAction SilentlyContinue
    if($embedded){
        $stream=$null
        try{$stream=[IO.MemoryStream]::new([Convert]::FromBase64String([string]$embedded),$false);$image=ConvertFrom-SjcGuiIconStream $stream;$result.Window=$image;$result.Brand=$image;$result.Source='embedded'}
        catch{$result.Window=$null;$result.Brand=$null;$result.Source=''}
        finally{if($stream){$stream.Dispose()}}
        if($result.Window){return $result}
    }
    $path=Get-SjcGuiIconPath
    if($path){
        $stream=$null
        try{$stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$image=ConvertFrom-SjcGuiIconStream $stream;$result.Window=$image;$result.Brand=$image;$result.Source=$path}
        catch{$result.Window=$null;$result.Brand=$null;$result.Source=''}
        finally{if($stream){$stream.Dispose()}}
    }
    return $result
}
function Find-SjcGuiNamedChild {
    param($Root,[string]$Name)
    if($null -eq $Root){return $null}
    $count=[Windows.Media.VisualTreeHelper]::GetChildrenCount($Root)
    for($i=0;$i -lt $count;$i++){
        $child=[Windows.Media.VisualTreeHelper]::GetChild($Root,$i)
        if($child -is [Windows.FrameworkElement] -and $child.Name -eq $Name){return $child}
        $found=Find-SjcGuiNamedChild $child $Name
        if($found){return $found}
    }
    return $null
}
function Get-SjcWorkbenchXaml {
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="星梦雨垃圾清理器 v__PRODUCT_VERSION__" Width="900" Height="680" MinWidth="760" MinHeight="600" WindowStartupLocation="CenterScreen" Background="#F3F6FB" FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#16213A" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
 <Window.Resources>
  <SolidColorBrush x:Key="Blue" Color="#2F6BFF"/>
  <SolidColorBrush x:Key="BlueSoft" Color="#EAF1FF"/>
  <SolidColorBrush x:Key="BlueInk" Color="#1C3F9E"/>
  <SolidColorBrush x:Key="Line" Color="#E6EBF3"/>
  <SolidColorBrush x:Key="Ink2" Color="#3D4A63"/>
  <SolidColorBrush x:Key="Ink3" Color="#6B7890"/>
  <Style x:Key="Muted" TargetType="TextBlock"><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  <Style x:Key="Glyph" TargetType="TextBlock"><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="14"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/></Style>
  <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style TargetType="Button"><Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="BorderBrush" Value="#D5DEEB"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="12,6"/><Setter Property="MinHeight" Value="32"/><Setter Property="Margin" Value="0,0,8,8"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Cursor" Value="Hand"/><Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="False"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#2F6BFF"/><Setter TargetName="Chrome" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F4F7FC"/><Setter Property="Foreground" Value="#16213A"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#EBEFF6"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger></Style.Triggers></Style>
  <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#2F6BFF"/><Setter Property="BorderBrush" Value="#2F6BFF"/><Setter Property="Foreground" Value="White"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#245BE0"/><Setter Property="Foreground" Value="White"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#1C4CC2"/></Trigger></Style.Triggers></Style>
  <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#C2342B"/><Setter Property="BorderBrush" Value="#C2342B"/><Setter Property="Foreground" Value="White"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#A82A22"/><Setter Property="Foreground" Value="White"/></Trigger></Style.Triggers></Style>
  <Style x:Key="LinkButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="Foreground" Value="#2F6BFF"/><Setter Property="FontWeight" Value="Normal"/><Setter Property="FontSize" Value="12"/><Setter Property="Padding" Value="6,2"/><Setter Property="MinHeight" Value="24"/><Setter Property="Margin" Value="4,0,0,0"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#EAF1FF"/><Setter Property="Foreground" Value="#1C3F9E"/></Trigger></Style.Triggers></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/></Style>
  <Style TargetType="RadioButton"><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Margin" Value="0,0,18,0"/><Setter Property="Cursor" Value="Hand"/></Style>
  <Style TargetType="GridViewColumnHeader"><Setter Property="Background" Value="#F7F9FD"/><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Padding" Value="8,6"/><Setter Property="BorderBrush" Value="#E6EBF3"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
  <Style x:Key="SmallButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Padding" Value="9,3"/><Setter Property="MinHeight" Value="28"/><Setter Property="Margin" Value="0,0,6,6"/><Setter Property="FontSize" Value="12"/></Style>
 </Window.Resources>
 <Grid>
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="16,8">
   <DockPanel>
    <Border DockPanel.Dock="Right" Background="{StaticResource BlueSoft}" CornerRadius="6" Padding="8,3" VerticalAlignment="Center"><TextBlock Text="v__PRODUCT_VERSION__" Foreground="{StaticResource BlueInk}" FontSize="12" FontWeight="Medium"/></Border>
    <Border Width="34" Height="34" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Margin="0,0,10,0"><Image x:Name="BrandIcon" Width="30" Height="30" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" AutomationProperties.Name="应用图标"/></Border>
    <StackPanel VerticalAlignment="Center"><TextBlock Text="星梦雨垃圾清理器" FontWeight="SemiBold" FontSize="15" TextWrapping="NoWrap"/><TextBlock Text="仅处理已核实的缓存与临时文件。扫描只生成预览，不提权，不结束应用。" Style="{StaticResource Muted}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/></StackPanel>
   </DockPanel>
  </Border>
  <Border Grid.Row="1" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="16,10,16,4">
   <StackPanel>
    <Border x:Name="NoticeBar" Visibility="Collapsed" Background="#FFF6E8" BorderBrush="#F3D9B1" BorderThickness="1" CornerRadius="6" Padding="10,5" Margin="0,0,0,8"><DockPanel><Button x:Name="DismissNoticeButton" DockPanel.Dock="Right" Style="{StaticResource LinkButton}"><TextBlock Text="知道了"/></Button><TextBlock DockPanel.Dock="Left" Text="{G:Warning}" Style="{StaticResource Glyph}" FontSize="12" Foreground="#B4630A" Margin="0,0,6,0"/><TextBlock x:Name="NoticeText" Foreground="#7A4A06" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/></DockPanel></Border>
    <DockPanel>
     <Button x:Name="AdvancedButton" DockPanel.Dock="Right" Style="{StaticResource SmallButton}" Margin="0" VerticalAlignment="Center"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Settings}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock x:Name="AdvancedButtonText" Text="高级自定义…"/></StackPanel></Button>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <TextBlock Text="清理强度" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,14,0"/>
      <RadioButton x:Name="ProfileLow" GroupName="CleaningProfile" Content="低" AutomationProperties.Name="低强度"/>
      <RadioButton x:Name="ProfileMedium" GroupName="CleaningProfile" Content="中" AutomationProperties.Name="中强度"/>
      <RadioButton x:Name="ProfileHigh" GroupName="CleaningProfile" Content="高" AutomationProperties.Name="高强度"/>
     </StackPanel>
    </DockPanel>
    <TextBlock x:Name="ProfileHint" Style="{StaticResource Muted}" Margin="0,6,0,0"/>
    <DockPanel x:Name="ProfileImpactPanel" Margin="0,2,0,0"><TextBlock x:Name="ProfileImpactGlyph" DockPanel.Dock="Left" Text="{G:Warning}" Style="{StaticResource Glyph}" FontSize="12" Foreground="#B4630A" VerticalAlignment="Top" Margin="0,1,6,0"/><TextBlock x:Name="ProfileImpact" Style="{StaticResource Muted}"/></DockPanel>
    <DockPanel Margin="0,8,0,0">
     <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
      <CheckBox x:Name="RecycleMode" Content="移入回收站（推荐）" IsChecked="True" VerticalAlignment="Center" Margin="0,0,12,8" ToolTip="移入回收站通常不会立即释放空间；取消勾选则永久删除"/>
      <Button x:Name="EmptyRecycleButton" Foreground="#C2342B" BorderBrush="#F1C7C3" Margin="0,0,0,8"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:EmptyRecycle}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="清空回收站…"/></StackPanel></Button>
     </StackPanel>
     <WrapPanel>
      <Button x:Name="ScanButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Scan}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="开始扫描"/></StackPanel></Button>
      <Button x:Name="CleanButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Clean}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock x:Name="CleanButtonText" Text="清理…"/></StackPanel></Button>
      <Button x:Name="FilesButton" ToolTip="扫描结束且结果有效后可用：在单独窗口逐个查看文件、分页、保留与导出" ToolTipService.ShowOnDisabled="True"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Files}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="查看文件明细"/></StackPanel></Button>
      <Button x:Name="CancelButton" Foreground="#C2342B" BorderBrush="#F1C7C3"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Cancel}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="取消任务"/></StackPanel></Button>
     </WrapPanel>
    </DockPanel>
   </StackPanel>
  </Border>
  <Grid Grid.Row="2" Margin="16,10,16,0">
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition x:Name="CategoryRow" Height="*" MinHeight="96"/></Grid.RowDefinitions>
   <Border Background="{StaticResource BlueSoft}" BorderBrush="#D6E3FF" BorderThickness="1" CornerRadius="8" Padding="12,7" Margin="0,0,0,8">
    <DockPanel>
     <TextBlock x:Name="ScopeText" DockPanel.Dock="Right" Foreground="{StaticResource BlueInk}" FontSize="12" VerticalAlignment="Center" TextWrapping="NoWrap" Margin="12,0,0,0"/>
     <WrapPanel VerticalAlignment="Center">
      <TextBlock Text="候选 " Foreground="#3D4A63"/><TextBlock x:Name="MetricCount" Text="—" FontWeight="SemiBold"/><TextBlock Text=" 个  ·  " Foreground="#3D4A63"/>
      <TextBlock x:Name="MetricBytes" Text="—" FontWeight="SemiBold"/><TextBlock Text="  ·  保留 " Foreground="#3D4A63"/><TextBlock x:Name="MetricKept" Text="—" FontWeight="SemiBold"/><TextBlock Text="  ·  " Foreground="#3D4A63"/>
      <TextBlock x:Name="PendingText" Text="尚未扫描" Foreground="{StaticResource BlueInk}" FontWeight="Medium"/>
     </WrapPanel>
    </DockPanel>
   </Border>
   <Border x:Name="PartialBar" Grid.Row="1" Visibility="Collapsed" Background="#FFF6E8" BorderBrush="#F3D9B1" BorderThickness="1" CornerRadius="8" Padding="10,5" Margin="0,0,0,8"><DockPanel><Button x:Name="PartialReasonButton" DockPanel.Dock="Right" Style="{StaticResource LinkButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Details}" Style="{StaticResource Glyph}" FontSize="11" Margin="0,0,4,0"/><TextBlock Text="查看原因"/></StackPanel></Button><TextBlock DockPanel.Dock="Left" Text="{G:Warning}" Style="{StaticResource Glyph}" FontSize="12" Foreground="#B4630A" VerticalAlignment="Top" Margin="0,1,6,0"/><TextBlock x:Name="PartialText" Foreground="#7A4A06" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/></DockPanel></Border>
   <Border Grid.Row="2" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,8">
    <DockPanel>
     <DockPanel DockPanel.Dock="Top" Margin="10,6,6,0">
      <Button x:Name="RestoreRuleButton" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" ToolTip="选中的分类全部候选重新计入清理范围"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Unkeep}" Style="{StaticResource Glyph}" FontSize="11" Margin="0,0,4,0"/><TextBlock Text="取消保留所选分类"/></StackPanel></Button>
      <Button x:Name="KeepRuleButton" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" ToolTip="选中的分类全部候选不处理"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Keep}" Style="{StaticResource Glyph}" FontSize="11" Margin="0,0,4,0"/><TextBlock Text="保留所选分类"/></StackPanel></Button>
      <TextBlock Text="分类结果" FontWeight="SemiBold" VerticalAlignment="Center"/>
     </DockPanel>
     <Grid Margin="1,4,1,1">
      <ListView x:Name="CategoryList" BorderThickness="0" Background="White" SelectionMode="Extended" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.IsVirtualizingWhenGrouping="True" ScrollViewer.CanContentScroll="True" ScrollViewer.HorizontalScrollBarVisibility="Disabled" AutomationProperties.Name="分类结果表格">
       <ListView.ItemContainerStyle><Style TargetType="ListViewItem"><Setter Property="Height" Value="30"/><Setter Property="Padding" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="BorderBrush" Value="#EEF1F6"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="AutomationProperties.Name" Value="{Binding Name}"/></Style></ListView.ItemContainerStyle>
       <ListView.GroupStyle><GroupStyle><GroupStyle.HeaderTemplate><DataTemplate><Border Background="#F7F9FD" BorderBrush="#E6EBF3" BorderThickness="0,0,0,1" Padding="8,4" Focusable="False"><StackPanel Orientation="Horizontal"><TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="#1C3F9E" FontSize="12"/><TextBlock Text="  ·  " Foreground="#6B7890" FontSize="12"/><TextBlock Text="{Binding ItemCount}" Foreground="#6B7890" FontSize="12"/><TextBlock Text=" 项" Foreground="#6B7890" FontSize="12"/></StackPanel></Border></DataTemplate></GroupStyle.HeaderTemplate></GroupStyle></ListView.GroupStyle>
       <ListView.View><GridView AllowsColumnReorder="False">
        <GridViewColumn Header="清理项目" Width="260"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" ToolTip="{Binding Detail}" Style="{StaticResource Cell}" FontWeight="Medium" Margin="12,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="状态" Width="190"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding StatusText}" ToolTip="{Binding StatusText}" Style="{StaticResource Cell}" Foreground="#3D4A63" FontSize="12"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="文件" Width="80"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CountText}" Style="{StaticResource Cell}" TextAlignment="Right" MinWidth="56"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="大小" Width="90"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding SizeText}" Style="{StaticResource Cell}" TextAlignment="Right" MinWidth="74"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="保留" Width="70"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding KeptText}" Style="{StaticResource Cell}" Foreground="#B4630A" TextAlignment="Right" MinWidth="50"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
       </GridView></ListView.View>
      </ListView>
      <TextBlock x:Name="CategoryEmpty" Text="当前范围没有规则。请选择强度或在高级自定义中勾选规则。" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
     </Grid>
    </DockPanel>
   </Border>
   <Border x:Name="FilesPanel" Background="White" BorderThickness="0" Padding="14,12,14,10">
    <Grid>
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <WrapPanel>
      <Button x:Name="KeepButton" Style="{StaticResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Keep}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock x:Name="KeepButtonText" Text="保留已勾选"/></StackPanel></Button>
      <Button x:Name="RestoreButton" Style="{StaticResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Unkeep}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock x:Name="RestoreButtonText" Text="取消保留已勾选"/></StackPanel></Button>
      <Button x:Name="SelectPageButton" Style="{StaticResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:CheckPage}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="勾选本页"/></StackPanel></Button>
      <Button x:Name="ClearSelectionButton" Style="{StaticResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:ClearSelection}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="清除勾选"/></StackPanel></Button>
      <Button x:Name="CopyPathButton" Style="{StaticResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Copy}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="复制路径"/></StackPanel></Button>
      <Button x:Name="ExportButton" Style="{StaticResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Export}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="完整导出 CSV"/></StackPanel></Button>
     </WrapPanel>
     <Grid Grid.Row="1">
      <ListView x:Name="CandidatesList" BorderBrush="{StaticResource Line}" BorderThickness="1" Background="White" SelectionMode="Single" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Standard" ScrollViewer.CanContentScroll="True" ScrollViewer.HorizontalScrollBarVisibility="Auto" AutomationProperties.Name="候选文件表格">
       <ListView.ItemContainerStyle><Style TargetType="ListViewItem"><Setter Property="Height" Value="30"/><Setter Property="Padding" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="BorderBrush" Value="#EEF1F6"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="AutomationProperties.Name" Value="{Binding FileName}"/></Style></ListView.ItemContainerStyle>
       <ListView.View><GridView AllowsColumnReorder="False">
        <GridViewColumn Header="勾选" Width="44"><GridViewColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding IsSelected,Mode=TwoWay}" AutomationProperties.Name="{Binding Path}" ToolTip="勾选用于保留/复制，跨页保持；不限定清理范围" Margin="4,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="文件名" Width="170"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding FileName}" ToolTip="{Binding Path}" Style="{StaticResource Cell}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="目录" Width="260"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Directory}" ToolTip="{Binding Directory}" Style="{StaticResource Cell}" Foreground="#6B7890" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="大小" Width="88"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding SizeText}" Style="{StaticResource Cell}" TextAlignment="Right" MinWidth="72"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="规则" Width="130"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding RuleName}" ToolTip="{Binding RuleName}" Style="{StaticResource Cell}" Foreground="#3D4A63"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="状态" Width="70"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding StateText}" FontWeight="Medium"><TextBlock.Style><Style TargetType="TextBlock" BasedOn="{StaticResource Cell}"><Setter Property="Foreground" Value="#3D4A63"/><Style.Triggers><DataTrigger Binding="{Binding IsKept}" Value="True"><Setter Property="Foreground" Value="#B4630A"/></DataTrigger></Style.Triggers></Style></TextBlock.Style></TextBlock></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
       </GridView></ListView.View>
      </ListView>
      <TextBlock x:Name="CandidatesEmpty" Text="尚无候选文件。扫描完成后在此逐个查看。" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
     </Grid>
     <DockPanel Grid.Row="2" Margin="0,6,0,0">
      <TextBlock x:Name="SelectionSummaryText" DockPanel.Dock="Right" Style="{StaticResource Muted}" TextWrapping="NoWrap" VerticalAlignment="Center"/>
      <Button x:Name="PreviousButton" Style="{StaticResource SmallButton}" Margin="0,0,6,0"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Previous}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="上一页"/></StackPanel></Button>
      <Button x:Name="NextButton" Style="{StaticResource SmallButton}" Margin="0,0,6,0"><StackPanel Orientation="Horizontal"><TextBlock Text="下一页"/><TextBlock Text="{G:Next}" Style="{StaticResource Glyph}" FontSize="12" Margin="5,0,0,0"/></StackPanel></Button>
      <TextBlock x:Name="PageText" VerticalAlignment="Center" Foreground="#6B7890" FontSize="12" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
     </DockPanel>
     <TextBox x:Name="SelectedPathText" Grid.Row="3" IsReadOnly="True" BorderThickness="0" Background="Transparent" TextWrapping="NoWrap" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12" Foreground="#3D4A63" Margin="0,4,0,0" Text="选中一个文件后显示完整路径" AutomationProperties.Name="选中文件完整路径"/>
     <TextBlock x:Name="FilesStatusText" Grid.Row="4" Style="{StaticResource Muted}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
    </Grid>
   </Border>
  </Grid>
  <Border x:Name="LogsPanel" Grid.Row="3" Visibility="Collapsed" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="16,6" Height="150">
   <DockPanel>
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
     <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
      <Button x:Name="OpenLogButton" Style="{StaticResource LinkButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:OpenLog}" Style="{StaticResource Glyph}" FontSize="11" Margin="0,0,4,0"/><TextBlock Text="打开日志"/></StackPanel></Button>
      <Button x:Name="DetailsButton" Style="{StaticResource LinkButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Details}" Style="{StaticResource Glyph}" FontSize="11" Margin="0,0,4,0"/><TextBlock Text="任务详情"/></StackPanel></Button>
      <Button x:Name="RemovePreviewButton" Style="{StaticResource LinkButton}" ToolTip="仅移除已放弃任务的预览/通道记录，不删除目标文件和日志"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:RemoveRecord}" Style="{StaticResource Glyph}" FontSize="11" Margin="0,0,4,0"/><TextBlock Text="移除旧预览记录"/></StackPanel></Button>
     </StackPanel>
     <TextBlock Text="本次会话任务记录（日志保存在本地私有目录，可能含完整路径）" Style="{StaticResource Muted}" VerticalAlignment="Center" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <Grid>
     <ListBox x:Name="HistoryList" BorderBrush="{StaticResource Line}" BorderThickness="1" ScrollViewer.HorizontalScrollBarVisibility="Disabled" AutomationProperties.Name="任务记录列表">
      <ListBox.ItemTemplate><DataTemplate><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="60"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="{Binding Time}" Foreground="#6B7890" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12"/><TextBlock Grid.Column="1" Text="{Binding Action}" FontSize="12"/><TextBlock Grid.Column="2" Text="{Binding Status}" FontWeight="Medium" FontSize="12"/><TextBlock Grid.Column="3" Text="{Binding Summary}" ToolTip="{Binding Summary}" Foreground="#6B7890" FontSize="12" TextTrimming="CharacterEllipsis"/></Grid></DataTemplate></ListBox.ItemTemplate>
     </ListBox>
     <TextBlock x:Name="HistoryEmpty" Text="尚无任务记录。" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
    </Grid>
   </DockPanel>
  </Border>
  <Border Grid.Row="4" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="16,6"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="StatusText" Text="就绪。先扫描预览，不自动删除文件。" Foreground="#6B7890" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/><ProgressBar x:Name="BusyProgress" Grid.Column="1" Width="100" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="12,0,0,0"/><Button x:Name="LogsToggle" Grid.Column="2" Style="{StaticResource LinkButton}" Margin="12,0,0,0"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Logs}" Style="{StaticResource Glyph}" FontSize="12" Margin="0,0,4,0"/><TextBlock x:Name="LogsToggleText" Text="任务记录"/></StackPanel></Button></Grid></Border>
 </Grid>
</Window>
'@
    return (Expand-SjcGuiGlyphs $xaml).Replace('__PRODUCT_VERSION__',(Get-SjcVersion))
}
function Test-SjcGuiProfileSupport {
    # 探测真实引擎三档接口：Set-SjcCleaningProfile -Context -CleaningProfile [-Invalidate]、Get-SjcPresetRuleIds、Get-SjcCleaningProfiles。
    $set=Get-Command Set-SjcCleaningProfile -CommandType Function -ErrorAction SilentlyContinue
    $preset=Get-Command Get-SjcPresetRuleIds -CommandType Function -ErrorAction SilentlyContinue
    $profiles=Get-Command Get-SjcCleaningProfiles -CommandType Function -ErrorAction SilentlyContinue
    if(-not $set -or -not $preset -or -not $profiles){return $false}
    return [bool]($set.Parameters.ContainsKey('Context') -and $set.Parameters.ContainsKey('CleaningProfile') -and $set.Parameters.ContainsKey('Invalidate') -and $preset.Parameters.ContainsKey('CleaningProfile'))
}
function Assert-SjcGuiProfileValue {
    param($Profile)
    if($Profile -isnot [string] -or $Profile -cnotin @('Low','Medium','High')){throw '清理强度必须为 Low、Medium 或 High。'}
    return [string]$Profile
}
function Get-SjcGuiContextProfile {
    # 引擎上下文是档位唯一真实来源；不合法时抛出而不是猜测默认值。
    param($Context)
    return (Assert-SjcGuiProfileValue (Get-SjcGuiValue $Context 'CleaningProfile' ''))
}
function Get-SjcGuiProfileInfo {
    # 标签、说明与影响全部来自引擎 Get-SjcCleaningProfiles，界面不另写影响文案。
    param([string]$Profile)
    foreach($item in @(Get-SjcCleaningProfiles)){if([string]$item.Id -ceq $Profile){return $item}}
    throw ('引擎未提供清理强度：'+$Profile)
}
function Get-SjcGuiProfileLabel {
    param([string]$Profile)
    try{return [string](Get-SjcGuiProfileInfo $Profile).Label}catch{return $Profile}
}
function Get-SjcGuiPresetIds {
    param($Context,[string]$Profile)
    return @(Get-SjcPresetRuleIds -Context $Context -CleaningProfile (Assert-SjcGuiProfileValue $Profile)|ForEach-Object{[string]$_})
}
function Get-SjcGuiEffectiveRuleIds {
    # 扫描实际集合：未启用自定义时精确等于当前强度预设；启用时为自定义勾选（按规则顺序）。
    param($State)
    if($State.CustomEnabled){return @($State.Rules|Where-Object{$State.CustomSelected.Contains([string]$_.Id)}|ForEach-Object{[string]$_.Id})}
    return @(Get-SjcGuiPresetIds $State.Context $State.Profile)
}
function New-SjcGuiState {
    param($Context,[switch]$TestMode)
    $configuration=Get-SjcContextConfiguration $Context
    if($TestMode -and -not $configuration.IsTest){throw '测试模式要求上下文的 IsTest 为 true；不允许非自建测试上下文或伪造 IsTest。'}
    $profile=Get-SjcGuiContextProfile $Context
    $rules=@(Get-SjcRules $Context)
    $ruleMap=@{};foreach($rule in $rules){$ruleMap[[string]$rule.Id]=$rule}
    $selected=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($id in @(Get-SjcGuiPresetIds $Context $profile)){[void]$selected.Add($id)}
    $custom=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    return @{Context=$Context;Rules=$rules;RuleMap=$ruleMap;Selected=$selected;Profile=$profile;CustomEnabled=$false;CustomSelected=$custom;CustomInitialized=$false;RuleRows=@();RecycleMode=$true;Scan=$null;ScanProfile='';ScanCustomEnabled=$false;ScanRuleIds=@();TaskDirectory='';Stale=$true;Excluded=@{};ExcludedRule=@{};CandidateSelection=@{};PageOffset=0;PageSize=200;PageItems=@();History=(New-Object 'System.Collections.Generic.List[object]');Task=$null;LocalJob=$null;Background=$null;FilesExpanded=$false;LogsExpanded=$false;TestMode=[bool]$TestMode;Busy=$false;Status='就绪。先扫描预览,不自动删除文件。';Notice='';LastResult=$null;Closing=$false;PendingScan=$false;PendingScope=$null;ProfileSupported=(Test-SjcGuiProfileSupport);Icon=$null}
}
function Test-SjcGuiPreviewOpen {
    param($State)
    return [bool]($State.Background -and $State.Background.Shared.Preview)
}
function Clear-SjcGuiScan {
    # 任何范围变化（强度、自定义开关、自定义勾选）都使旧扫描、保留与勾选失效。
    param($App)
    $s=$App.State
    $s.Scan=$null;$s.ScanProfile='';$s.ScanCustomEnabled=$false;$s.ScanRuleIds=@();$s.TaskDirectory='';$s.Stale=$true
    $s.PageItems=@();$s.PageOffset=0;$s.CandidateSelection.Clear();$s.Excluded.Clear();$s.ExcludedRule.Clear()
    if($App.Ui.CandidatesList){$App.Ui.CandidatesList.SelectedItem=$null}
}
function Request-SjcGuiScope {
    # 范围变化入口。打开的预览会话持有旧计划句柄：先异步释放（busy 冻结），完成后再调用引擎 Set-SjcCleaningProfile。
    param($App,[Parameter(Mandatory=$true)][hashtable]$Change)
    $s=$App.State
    if($s.Busy -or $s.PendingScope){Sync-SjcGuiScopeControls $App;throw '请等待当前任务结束后再调整范围。'}
    if(-not $s.ProfileSupported){Sync-SjcGuiScopeControls $App;throw '当前引擎不支持三档强度接口。'}
    if(Test-SjcGuiPreviewOpen $s){
        $s.PendingScope=$Change
        Start-SjcGuiLocalJob $App 'Close' @{}
        Set-SjcGuiStatus $App '正在释放旧预览，完成后应用新范围。'
        return
    }
    Complete-SjcGuiScope $App $Change
}
function Complete-SjcGuiScope {
    # Change: Profile（目标强度）、CustomEnabled（目标自定义开关）、CustomIds（可选，新自定义勾选）。
    # 同档范围变化用 -Invalidate，使已封存旧计划失效；失败时以引擎实际状态恢复界面。
    param($App,[hashtable]$Change)
    $s=$App.State
    $before=@{Profile=$s.Profile;CustomEnabled=$s.CustomEnabled;Custom=@($s.CustomSelected)}
    try{
        $target=Assert-SjcGuiProfileValue ([string]$Change.Profile)
        $customTarget=[bool]$Change.CustomEnabled
        if($target -ceq $s.Profile){Set-SjcCleaningProfile -Context $s.Context -CleaningProfile $target -Invalidate}
        else{Set-SjcCleaningProfile -Context $s.Context -CleaningProfile $target}
        $actual=Get-SjcGuiContextProfile $s.Context
        if($actual -cne $target){throw '引擎强度未切换成功。'}
        $s.Profile=$actual
        $s.Rules=@($s.Context.Rules);if($s.Rules.Count -eq 0){$s.Rules=@(Get-SjcRules $s.Context)}
        $s.RuleMap=@{};foreach($rule in $s.Rules){$s.RuleMap[[string]$rule.Id]=$rule}
        if($Change.ContainsKey('CustomIds') -and $null -ne $Change.CustomIds){$s.CustomSelected.Clear();foreach($id in @($Change.CustomIds)){if($s.RuleMap.ContainsKey([string]$id)){[void]$s.CustomSelected.Add([string]$id)}};$s.CustomInitialized=$true}
        if($customTarget -and -not $s.CustomInitialized){foreach($id in @(Get-SjcGuiPresetIds $s.Context $actual)){[void]$s.CustomSelected.Add($id)};$s.CustomInitialized=$true}
        foreach($id in @($s.CustomSelected)){if(-not $s.RuleMap.ContainsKey($id)){[void]$s.CustomSelected.Remove($id)}}
        $s.CustomEnabled=$customTarget
        $s.Selected.Clear();foreach($id in @(Get-SjcGuiEffectiveRuleIds $s)){[void]$s.Selected.Add($id)}
        Clear-SjcGuiScan $App
        if($before.Profile -cne $actual){Save-SjcGuiPreferences $App}
        $label=Get-SjcGuiProfileLabel $actual
        $scope=if($s.CustomEnabled){'高级自定义 '+$s.Selected.Count+' 条规则（仅本次会话）'}else{$label+'预设 '+$s.Selected.Count+' 条规则'}
        Update-SjcGuiRuleRows $App
        Set-SjcGuiStatus $App ('已应用：'+$scope+'。旧扫描与保留已清空，需重新扫描。')
    }catch{
        $message=$_.Exception.Message
        # 以引擎实际档位为准恢复；Set-SjcCleaningProfile 可能已写入失效标记，旧扫描一律视为失效（只会更保守）。
        try{$s.Profile=Get-SjcGuiContextProfile $s.Context}catch{$s.Profile=$before.Profile}
        $s.CustomEnabled=[bool]$before.CustomEnabled
        $s.CustomSelected.Clear();foreach($id in $before.Custom){[void]$s.CustomSelected.Add([string]$id)}
        $s.Rules=@($s.Context.Rules);$s.RuleMap=@{};foreach($rule in $s.Rules){$s.RuleMap[[string]$rule.Id]=$rule}
        $s.Selected.Clear();foreach($id in @(Get-SjcGuiEffectiveRuleIds $s)){[void]$s.Selected.Add($id)}
        Clear-SjcGuiScan $App
        Update-SjcGuiRuleRows $App
        Set-SjcGuiStatus $App ('范围调整失败，当前仍为'+(Get-SjcGuiProfileLabel $s.Profile)+$(if($s.CustomEnabled){'（高级自定义）'}else{'预设'})+'，需重新扫描：'+$message)
    }
    Update-SjcGuiView $App
}
function Set-SjcGuiProfileChoice {
    # 单选 Checked 即应用，没有“应用”按钮。
    param($App,[string]$Profile)
    if($App.Syncing){return}
    $s=$App.State
    if($Profile -ceq $s.Profile -and -not $s.CustomEnabled -and -not $s.PendingScope){return}
    try{Request-SjcGuiScope $App @{Profile=$Profile;CustomEnabled=$false}}
    catch{Set-SjcGuiStatus $App ('未切换强度：'+$_.Exception.Message);Sync-SjcGuiScopeControls $App}
}
function Set-SjcGuiCustomEnabled {
    # 开启：使用内存中的自定义草稿（首次为当前预设）；关闭：恢复当前强度预设，草稿保留在本会话内存。
    param($App,[bool]$Enabled)
    if($App.Syncing){return}
    $s=$App.State
    if($Enabled -eq $s.CustomEnabled){return}
    try{Request-SjcGuiScope $App @{Profile=$s.Profile;CustomEnabled=$Enabled}}
    catch{Set-SjcGuiStatus $App ('未切换高级自定义：'+$_.Exception.Message);Sync-SjcGuiScopeControls $App}
}
function Set-SjcGuiCustomRule {
    # 自定义规则勾选改动即时生效（同档 -Invalidate），并清空旧扫描。
    param($App,$CheckBox)
    if($App.Syncing -or $null -eq $CheckBox -or $CheckBox -isnot [Windows.Controls.CheckBox]){return}
    $row=$CheckBox.DataContext
    if($null -eq $row -or -not $row.PSObject.Properties['Id']){return}
    $s=$App.State;$want=[bool]$CheckBox.IsChecked
    if(-not $s.CustomEnabled -or $want -eq $s.CustomSelected.Contains([string]$row.Id)){return}
    $ids=New-Object 'System.Collections.Generic.List[string]';foreach($id in $s.CustomSelected){if($id -cne [string]$row.Id){[void]$ids.Add($id)}}
    if($want){[void]$ids.Add([string]$row.Id)}
    try{Request-SjcGuiScope $App @{Profile=$s.Profile;CustomEnabled=$true;CustomIds=$ids.ToArray()}}
    catch{Set-SjcGuiStatus $App ('未调整规则：'+$_.Exception.Message);Sync-SjcGuiScopeControls $App}
}
function Update-SjcGuiRuleRows {
    # 规则行（高级自定义草稿窗使用）；Selected 反映内存自定义勾选。主窗不再内嵌规则列表。
    param($App)
    $s=$App.State
    $levelText=@{Low='低档起';Medium='中档起';High='高档起';CustomOnly='仅自定义'}
    $s.RuleRows=@($s.Rules|ForEach-Object{
        $level=[string](Get-SjcGuiValue $_ 'PresetLevel' '')
        $lt=$levelText[$level];if(-not $lt){$lt=$level}
        [pscustomobject]@{Id=[string]$_.Id;Name=[string]$_.Name;Group=[string]$_.Group;LevelText=$lt;AgeText=('≥ '+[string]$_.MinimumAgeHours+' 小时');Selected=$s.CustomSelected.Contains([string]$_.Id);Detail=([string]$_.Note+"`r`n"+[string]$_.Root+"`r`n"+$(if($_.Available){'目录存在'}else{'目录不存在，扫描时跳过'}))}
    })
    if($App.Ui.ContainsKey('RulesList') -and $App.Ui.RulesList){$App.Syncing=$true;try{$App.Ui.RulesList.ItemsSource=$s.RuleRows}finally{$App.Syncing=$false}}
}
function Sync-SjcGuiScopeControls {
    # 控件回写为真实状态；Syncing 期间事件处理器不触发范围变化。
    # 高级自定义生效时三档单选全部不选中，点击任一档位即可恢复该档预设。
    param($App)
    $s=$App.State;$u=$App.Ui
    $App.Syncing=$true
    try{
        $preset=-not $s.CustomEnabled
        $u.ProfileLow.IsChecked=($preset -and $s.Profile -ceq 'Low');$u.ProfileMedium.IsChecked=($preset -and $s.Profile -ceq 'Medium');$u.ProfileHigh.IsChecked=($preset -and $s.Profile -ceq 'High')
        $u.AdvancedButtonText.Text=if($s.CustomEnabled){'高级自定义（'+$s.Selected.Count+' 条）…'}else{'高级自定义…'}
        foreach($row in @($s.RuleRows)){$row.Selected=$s.CustomSelected.Contains($row.Id)}
        $u.RecycleMode.IsChecked=[bool]$s.RecycleMode
    }finally{$App.Syncing=$false}
}
function Update-SjcGuiProfile {
    param($App)
    $s=$App.State;$u=$App.Ui
    if(-not $u.ProfileHint){return}
    $idle=-not $s.Busy -and -not $s.PendingScope
    foreach($name in @('ProfileLow','ProfileMedium','ProfileHigh','AdvancedButton')){$u[$name].IsEnabled=($idle -and $s.ProfileSupported)}
    if(-not $s.ProfileSupported){$u.ProfileHint.Text='当前引擎未提供三档强度接口，无法扫描。';$u.ProfileImpact.Text='';$u.ProfileImpactPanel.Visibility='Collapsed';return}
    $info=Get-SjcGuiProfileInfo $s.Profile
    $prefix=if($s.CustomEnabled){'高级自定义（基于'+$info.Label+'）：'+$s.Selected.Count+' 条规则，仅本次会话有效；点击低/中/高恢复预设。'}else{$info.Label+'：'+$info.Description}
    $u.ProfileHint.Text=($prefix+' 改变范围后需重新扫描。')
    $u.ProfileImpact.Text=('影响：'+[string]$info.Impact)
    $u.ProfileImpactPanel.Visibility='Visible'
    $high=($s.Profile -ceq 'High')
    $u.ProfileImpact.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($high){'#9A4F06'}else{'#6B7890'}))
    $u.ProfileImpactGlyph.Visibility=if($high){'Visible'}else{'Collapsed'}
    $u.AdvancedButton.ToolTip=('在草稿窗中逐条选择规则（共 {0} 条）；点“确定”才应用并使旧扫描失效，取消或关闭不改变范围。不保存到下次启动。' -f $s.Rules.Count)
}
function Save-SjcGuiPreferences {
    # 偏好只保存强度与回收站模式；引擎按强度归一化预设并强制 CustomEnabled=false。自定义草稿从不落盘。
    param($App)
    if($App.State.TestMode){return}
    try{[void](Save-SjcPreferences -Context $App.State.Context -Preferences ([pscustomobject]@{RecycleMode=[bool]$App.State.RecycleMode;SelectedRuleIds=[string[]]@(Get-SjcGuiPresetIds $App.State.Context $App.State.Profile);CleaningProfile=[string]$App.State.Profile;CustomEnabled=$false}))}
    catch{Set-SjcGuiStatus $App ('设置未能保存，本次会话仍可使用：'+$_.Exception.Message)}
}
function Set-SjcGuiNotice {
    param($App,[string]$Text)
    $App.State.Notice=$Text
    $App.Ui.NoticeText.Text=$Text
    $App.Ui.NoticeBar.Visibility=if($Text){'Visible'}else{'Collapsed'}
}
function Set-SjcGuiPanel {
    # Files：单实例非模态 owned 文件明细窗（复用原 FilesPanel 控件）；Logs：状态栏任务记录。
    param($App,[ValidateSet('Files','Logs')][string]$Panel,[bool]$Expanded)
    $s=$App.State;$u=$App.Ui
    if($Panel -eq 'Files'){
        if($Expanded){[void](Open-SjcGuiFilesWindow $App)}else{Close-SjcGuiFilesWindow $App}
    }else{
        $s.LogsExpanded=$Expanded
        $u.LogsPanel.Visibility=if($Expanded){'Visible'}else{'Collapsed'}
        $u.LogsToggleText.Text=if($Expanded){'收起任务记录'}else{'任务记录'}
    }
}
function Test-SjcGuiFilesAvailable {
    # 扫描结束且计划有效（Success 或 Partial，未因范围变化失效）才可查看明细。
    param($State)
    return [bool]($null -ne $State.Scan -and -not $State.Stale -and [string]$State.Scan.Status -in @('Success','Partial') -and [string](Get-SjcGuiValue $State.Scan 'PlanPath' ''))
}
function Open-SjcGuiFilesWindow {
    # 单实例：已打开则置前；主窗未显示（隔离渲染）时只创建不显示。共享主窗资源字典，关闭时归还 FilesPanel 以便重开。
    param($App,[switch]$NoShow)
    $s=$App.State;$u=$App.Ui
    $existing=$App.FilesWindow
    if($existing){
        if(-not $NoShow -and $existing.IsLoaded){if($existing.WindowState -eq 'Minimized'){$existing.WindowState='Normal'};[void]$existing.Activate()}
        elseif(-not $NoShow -and $u.Window.IsLoaded){$existing.Owner=$u.Window;$existing.WindowStartupLocation='CenterOwner';$existing.Show();[void]$existing.Activate()}
        $s.FilesExpanded=$true;return $existing
    }
    $panel=$u.FilesPanel
    if($panel.Parent -is [Windows.Controls.Panel]){$panel.Parent.Children.Remove($panel)}
    elseif($panel.Parent -is [Windows.Window]){$panel.Parent.Content=$null}
    $window=[Windows.Window]::new()
    $window.Title='文件明细';$window.Width=920;$window.Height=600;$window.MinWidth=640;$window.MinHeight=420
    $window.Background=[Windows.Media.Brushes]::White;$window.FontFamily=$u.Window.FontFamily;$window.FontSize=$u.Window.FontSize;$window.Foreground=$u.Window.Foreground
    $window.UseLayoutRounding=$true;[Windows.Media.TextOptions]::SetTextFormattingMode($window,[Windows.Media.TextFormattingMode]::Display)
    $window.ShowInTaskbar=$false
    [void]$window.Resources.MergedDictionaries.Add($u.Window.Resources)
    if($u.Window.Icon){$window.Icon=$u.Window.Icon}
    $window.Tag=$App
    $window.Content=$panel
    $window.Add_Closed({param($sender,$event) $app=$sender.Tag;try{$sender.Content=$null}catch{};if($app.FilesWindow -and [object]::ReferenceEquals($app.FilesWindow,$sender)){$app.FilesWindow=$null;$app.State.FilesExpanded=$false}})
    $App.FilesWindow=$window;$s.FilesExpanded=$true
    Update-SjcGuiView $App
    if(-not $NoShow -and $u.Window.IsLoaded){
        $window.Owner=$u.Window;$window.WindowStartupLocation='CenterOwner'
        $window.Show();[void]$window.Activate()
    }
    return $window
}
function Close-SjcGuiFilesWindow {
    param($App)
    $window=$App.FilesWindow
    $App.FilesWindow=$null;$App.State.FilesExpanded=$false
    if($window){try{$window.Close()}catch{};try{$window.Content=$null}catch{}}
}
function New-SjcGuiApp {
    param([Parameter(Mandatory=$true)]$State)
    Initialize-SjcDesktop
    $xamlText=Get-SjcWorkbenchXaml
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($xamlText))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    $ui=@{Window=$window}
    foreach($match in [regex]::Matches($xamlText,'x:Name="([A-Za-z0-9]+)"')){$name=$match.Groups[1].Value;$found=$window.FindName($name);if($found){$ui[$name]=$found}}
    $app=@{State=$State;Ui=$ui;Timer=$null;ResourcesClosed=$false;Syncing=$false;FilesWindow=$null;Maintenance=$null}
    # 文件明细控件迁出主 VisualTree（名称已在主窗 namescope 注册），按需挂到独立窗口。
    if($ui.FilesPanel.Parent -is [Windows.Controls.Panel]){$ui.FilesPanel.Parent.Children.Remove($ui.FilesPanel)}
    $window.Tag=$app
    $State.Icon=Get-SjcGuiAppIcon
    if($State.Icon.Window){$window.Icon=$State.Icon.Window}
    if($State.Icon.Brand){$ui.BrandIcon.Source=$State.Icon.Brand}
    $accessible=@{ScanButton='开始扫描';CleanButton='清理未保留候选';CancelButton='取消任务';EmptyRecycleButton='清空回收站';FilesButton='查看文件明细';AdvancedButton='高级自定义规则';PartialReasonButton='查看扫描不完整原因';LogsToggle='任务记录';DismissNoticeButton='关闭提示';KeepRuleButton='保留所选分类';RestoreRuleButton='取消保留所选分类';KeepButton='保留已勾选';RestoreButton='取消保留已勾选';SelectPageButton='勾选本页';ClearSelectionButton='清除勾选';CopyPathButton='复制路径';ExportButton='完整导出 CSV';PreviousButton='上一页';NextButton='下一页';OpenLogButton='打开日志';DetailsButton='任务详情';RemovePreviewButton='移除旧预览记录'}
    foreach($name in @($accessible.Keys)){
        $ui[$name].Tag=@{App=$app;Name=$name}
        [Windows.Automation.AutomationProperties]::SetName($ui[$name],$accessible[$name])
        $ui[$name].Add_Click({param($sender,$event) try{Invoke-SjcGuiCommand $sender.Tag.App $sender.Tag.Name}catch{Set-SjcGuiStatus $sender.Tag.App ('操作失败: '+$_.Exception.Message)}})
    }
    foreach($pair in @(@('ProfileLow','Low'),@('ProfileMedium','Medium'),@('ProfileHigh','High'))){
        $ui[$pair[0]].Tag=@{App=$app;Profile=$pair[1]}
        $ui[$pair[0]].Add_Checked({param($sender,$event) Set-SjcGuiProfileChoice $sender.Tag.App $sender.Tag.Profile})
    }
    $ui.RecycleMode.Tag=$app
    $ui.RecycleMode.Add_Click({param($sender,$event) $app=$sender.Tag;if($app.State.Busy){$app.Syncing=$true;$sender.IsChecked=$app.State.RecycleMode;$app.Syncing=$false;return};$app.State.RecycleMode=[bool]$sender.IsChecked;Save-SjcGuiPreferences $app;Update-SjcGuiView $app})
    $ui.CandidatesList.Tag=$app
    $ui.CandidatesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiCandidateSelection $sender.Tag $event.OriginalSource})
    $ui.CandidatesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiCandidateSelection $sender.Tag $event.OriginalSource})
    $ui.CandidatesList.Add_SelectionChanged({param($sender,$event) Update-SjcGuiCandidateDetail $sender.Tag})
    $ui.CandidatesList.Add_SizeChanged({param($sender,$event) Resize-SjcGuiCandidateColumns $sender})
    $ui.CategoryList.Tag=$app
    $ui.CategoryList.Add_SelectionChanged({param($sender,$event) Update-SjcGuiCategoryButtons $sender.Tag})
    $ui.CategoryList.Add_SizeChanged({param($sender,$event) Resize-SjcGuiCategoryColumns $sender})
    $window.Add_Closing({param($sender,$event) $app=$sender.Tag;if($app.Maintenance){$event.Cancel=$true;Set-SjcGuiStatus $app '系统维护仍在运行，请等待结果；不会强制终止。'}elseif($app.State.Busy){$event.Cancel=$true;Request-SjcGuiCancel $app;Set-SjcGuiStatus $app '正在取消。请等待后台任务结束后再关闭窗口。'}else{Close-SjcGuiFilesWindow $app;Remove-SjcGuiApp $app}})
    $window.Add_Closed({param($sender,$event) Remove-SjcGuiApp $sender.Tag})
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $tick={param($sender,$event) try{Invoke-SjcGuiMaintenanceTick $app;Invoke-SjcGuiTick $app}catch{Set-SjcGuiStatus $app ('后台反馈失败: '+$_.Exception.Message)}}.GetNewClosure()
    $timer.Add_Tick($tick)
    $app.Timer=$timer;$timer.Start()
    Update-SjcGuiRuleRows $app
    Set-SjcGuiPanel $app 'Files' $false;Set-SjcGuiPanel $app 'Logs' $false
    Update-SjcGuiView $app
    return $app
}
function Set-SjcGuiStatus {
    param($App,[string]$Text)
    $App.State.Status=$Text;$App.Ui.StatusText.Text=$Text;$App.Ui.StatusText.ToolTip=$Text
    if($App.Ui.FilesStatusText){$App.Ui.FilesStatusText.Text=$Text;$App.Ui.FilesStatusText.ToolTip=$Text}
}
function Test-SjcGuiCleanable {
    param($State)
    return ($null -ne $State.Scan -and -not $State.Stale -and $State.Scan.Status -in @('Success','Partial') -and $State.Scan.CandidateCount -gt 0)
}
function Get-SjcGuiCategoryStatusMap {
    return @{Success='已扫描';Partial='部分完成（已发现量）';Missing='目录不存在，跳过';RunningProcess='应用运行中，跳过';Failed='读取失败';Cancelled='扫描已取消';Pending='尚未扫描';UnsupportedConfiguration='检测到自定义缓存配置，未扫描'}
}
function Get-SjcGuiCategoryRows {
    # 分类主表：有有效扫描时来自扫描封存分类；否则列出当前生效范围的规则（未扫描）。
    param($State)
    $s=$State
    $keptCount=@{};$keptBytes=@{}
    foreach($id in @($s.Excluded.Keys)){$rule=[string]$s.ExcludedRule[$id];$keptCount[$rule]=1+[int64]$keptCount[$rule];$keptBytes[$rule]=[int64]$keptBytes[$rule]+[int64]$s.Excluded[$id]}
    $statusMap=Get-SjcGuiCategoryStatusMap
    $fresh=($null -ne $s.Scan -and -not $s.Stale)
    $source=if($fresh){@($s.Scan.Categories)}else{@($s.Rules|Where-Object{$s.Selected.Contains([string]$_.Id)}|ForEach-Object{[pscustomobject]@{RuleId=$_.Id;Name=$_.Name;Group=$_.Group;Root=$_.Root;Note=$_.Note;Count=0;Bytes=0;Status=$(if($s.Scan){'Stale'}else{'Pending'})}})}
    return @($source|ForEach-Object{
        $ruleId=[string](Get-SjcGuiValue $_ 'RuleId' '');$status=[string](Get-SjcGuiValue $_ 'Status' 'Pending')
        $text=if($status -eq 'Stale'){'需重新扫描'}else{$statusMap[$status]};if(-not $text){$text=$status}
        $counted=$fresh -and $status -in @('Success','Partial')
        $count=[int64](Get-SjcGuiValue $_ 'Count' 0);$kept=[int64]$keptCount[$ruleId]
        $group=[string](Get-SjcGuiValue $_ 'Group' '');if(-not $group){$group='未分组'}
        [pscustomobject]@{RuleId=$ruleId;Group=$group;Name=[string](Get-SjcGuiValue $_ 'Name' $ruleId);StatusText=$text;Count=$count;CountText=$(if($counted){'{0:N0}' -f $count}else{'—'});SizeText=$(if($counted){Format-SjcGuiSize ([int64](Get-SjcGuiValue $_ 'Bytes' 0))}else{'—'});Kept=$kept;KeptText=$(if($kept){'{0:N0}' -f $kept}else{''});Detail=([string](Get-SjcGuiValue $_ 'Note' '')+"`r`n"+[string](Get-SjcGuiValue $_ 'Root' ''))}
    })
}
function Get-SjcGuiSelectedCategoryRuleIds {
    # 只取真实分类行（分组标题不是数据项，也不进入 SelectedItems）；再按 RuleId 校验，防止误把分组当规则。
    param($App)
    return [string[]]@($App.Ui.CategoryList.SelectedItems|Where-Object{$_ -and $_.PSObject.Properties['RuleId'] -and [string]$_.RuleId -and $App.State.RuleMap.ContainsKey([string]$_.RuleId) -and [int64]$_.Count -gt 0}|ForEach-Object{[string]$_.RuleId})
}
function Update-SjcGuiCategoryButtons {
    param($App)
    $s=$App.State;$u=$App.Ui
    $ok=(-not $s.Busy) -and (Test-SjcGuiCleanable $s) -and @(Get-SjcGuiSelectedCategoryRuleIds $App).Count -gt 0
    $u.KeepRuleButton.IsEnabled=$ok;$u.RestoreRuleButton.IsEnabled=$ok
}
function Resize-SjcGuiCategoryColumns {
    # 列：清理项目/状态/文件/大小/保留（分组由 GroupStyle 标题承担，不再重复列）。
    param($List)
    if(-not $List -or -not $List.View -or $List.ActualWidth -le 0){return}
    $columns=$List.View.Columns;$available=$List.ActualWidth-24
    $columns[2].Width=80;$columns[3].Width=92;$columns[4].Width=64
    $rest=[math]::Max(200,$available-80-92-64)
    $columns[0].Width=[math]::Floor($rest*0.58);$columns[1].Width=$rest-$columns[0].Width
}
function Get-SjcGuiExcludedBytes {
    param($State)
    [int64]$total=0;foreach($value in $State.Excluded.Values){$total+=[int64]$value};return $total
}
function Sync-SjcGuiPageSelection {
    param($App)
    # 当前页行对象 IsSelected 与跨页勾选表对齐；勾选表是唯一真实来源。
    $s=$App.State
    foreach($row in @($App.Ui.CandidatesList.Items)){
        if($row.IsSelected){$s.CandidateSelection[$row.Id]=[pscustomobject]@{Path=$row.Path;Length=[int64]$row.Length;RuleId=$row.RuleId}}
        else{$s.CandidateSelection.Remove($row.Id)}
    }
}
function Set-SjcGuiCandidateSelection {
    param($App,$CheckBox)
    if($null -eq $CheckBox -or $CheckBox -isnot [Windows.Controls.CheckBox]){return}
    $row=$CheckBox.DataContext
    if($null -eq $row -or -not $row.PSObject.Properties['Id']){return}
    if($App.State.Busy -or -not (Test-SjcGuiCleanable $App.State)){if([bool]$CheckBox.IsChecked -ne [bool]$row.IsSelected){$CheckBox.IsChecked=[bool]$row.IsSelected};return}
    $row.IsSelected=[bool]$CheckBox.IsChecked
    if($row.IsSelected){$App.State.CandidateSelection[$row.Id]=[pscustomobject]@{Path=$row.Path;Length=[int64]$row.Length;RuleId=$row.RuleId}}else{$App.State.CandidateSelection.Remove($row.Id)}
    if(($CheckBox.IsKeyboardFocusWithin -or $CheckBox.IsMouseOver) -and $App.Ui.CandidatesList.Items.Contains($row)){$App.Ui.CandidatesList.SelectedItem=$row}
    Update-SjcGuiFileChrome $App
}
function Update-SjcGuiCandidateDetail {
    param($App)
    $current=$App.Ui.CandidatesList.SelectedItem
    $App.Ui.SelectedPathText.Text=if($current){$current.Path+$(if($current.Modified){'    （修改于 '+$current.Modified+'）'}else{''})}else{'选中一个文件后显示完整路径'}
}
function Update-SjcGuiFileChrome {
    param($App)
    $s=$App.State;$u=$App.Ui;$idle=-not $s.Busy;$cleanable=Test-SjcGuiCleanable $s
    $checked=$s.CandidateSelection.Count
    $onPage=@($u.CandidatesList.Items|Where-Object IsSelected).Count
    $u.KeepButtonText.Text=if($checked){'保留已勾选 ('+$checked+')'}else{'保留已勾选'}
    $u.RestoreButtonText.Text=if($checked){'取消保留已勾选 ('+$checked+')'}else{'取消保留已勾选'}
    foreach($name in @('KeepButton','RestoreButton','CopyPathButton')){$u[$name].IsEnabled=$idle -and $cleanable -and $checked -gt 0}
    $u.ClearSelectionButton.IsEnabled=$idle -and $checked -gt 0
    $u.SelectPageButton.IsEnabled=$idle -and $cleanable -and $u.CandidatesList.Items.Count -gt 0
    $u.ExportButton.IsEnabled=$idle -and $cleanable
    # 勾选只用于保留/复制；清理范围始终是全部未保留候选（顶部统计行显示数量）。
    $u.CandidatesEmpty.Text=if(-not (Test-SjcGuiFilesAvailable $s)){'当前明细已失效（范围变化、重新扫描或已清理）。请重新扫描后再查看。'}elseif($s.LocalJob -and $s.LocalJob.Kind -in @('Open','Page')){'正在读取候选分页…'}elseif([int64]$s.Scan.CandidateCount -eq 0){'本次扫描没有发现候选文件。'}else{'当前页没有候选文件。'}
    $u.SelectionSummaryText.Text=if($checked){('已勾选 {0} 个（本页 {1}，其他页 {2}）；清理不限于勾选' -f $checked,$onPage,($checked-$onPage))}else{'未勾选；清理处理全部未保留候选，无需勾选'}
    Update-SjcGuiCandidateDetail $App
}
function Resize-SjcGuiCandidateColumns {
    param($List)
    if(-not $List -or -not $List.View -or $List.ActualWidth -le 0){return}
    # 列：勾选/文件名/目录/大小/规则/状态。窄窗口先压缩文件名、规则和目录，保证状态列可见。
    $columns=$List.View.Columns
    $available=$List.ActualWidth-26
    $columns[0].Width=44;$columns[3].Width=84;$columns[5].Width=60
    $rest=$available-44-84-60
    $name=[math]::Max(110,[math]::Min(200,[math]::Floor($rest*0.30)))
    $rule=[math]::Max(90,[math]::Min(150,[math]::Floor($rest*0.22)))
    $columns[1].Width=$name;$columns[4].Width=$rule
    $columns[2].Width=[math]::Max(100,$rest-$name-$rule)
}
function Get-SjcGuiCandidateRows {
    param($State)
    $s=$State
    return @($s.PageItems|ForEach-Object{
        $item=$_;$rule=$null;if($item.RuleId -and $s.RuleMap.ContainsKey([string]$item.RuleId)){$rule=$s.RuleMap[[string]$item.RuleId]}
        $path=[string]$item.Path;$cut=$path.LastIndexOf('\')
        $isKept=$s.Excluded.ContainsKey($item.Id)
        $modified='';$raw=Get-SjcGuiValue $item 'LastWriteUtc' ''
        if($raw){try{$modified=([datetime]::Parse([string]$raw,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')}catch{$modified=''}}
        [pscustomobject]@{
            Id=$item.Id
            Path=$path
            FileName=$(if($cut -ge 0){$path.Substring($cut+1)}else{$path})
            Directory=$(if($cut -gt 0){$path.Substring(0,$cut)}else{''})
            RuleId=$item.RuleId
            RuleName=$(if($rule){$rule.Name}else{[string]$item.RuleId})
            Length=[int64]$item.Length
            SizeText=(Format-SjcGuiSize $item.Length)
            Modified=$modified
            StateText=$(if($isKept){'保留'}else{'待处理'})
            IsKept=$isKept
            IsSelected=$s.CandidateSelection.ContainsKey($item.Id)
        }
    })
}
function Update-SjcGuiView {
    param($App)
    $s=$App.State;$u=$App.Ui;$idle=(-not $s.Busy) -and (-not $s.PendingScope);$cleanable=Test-SjcGuiCleanable $s
    Sync-SjcGuiScopeControls $App
    $u.ScopeText.Text=('{0}  ·  {1} 条规则  ·  {2}' -f $(if($s.CustomEnabled){'高级自定义'}else{(Get-SjcGuiProfileLabel $s.Profile)+'预设'}),$s.Selected.Count,$(if($s.RecycleMode){'移入回收站'}else{'永久删除'}))
    $u.RecycleMode.IsEnabled=$idle;$u.EmptyRecycleButton.IsEnabled=$idle
    $u.ScanButton.IsEnabled=$idle -and $s.ProfileSupported -and $s.Selected.Count -gt 0
    $u.CleanButton.IsEnabled=$idle -and $cleanable
    $filesOk=Test-SjcGuiFilesAvailable $s
    $u.FilesButton.IsEnabled=$filesOk
    $partial=($null -ne $s.Scan -and -not $s.Stale -and [string]$s.Scan.Status -eq 'Partial')
    $u.PartialBar.Visibility=if($partial){'Visible'}else{'Collapsed'}
    if($partial){$u.PartialText.Text=('扫描不完整：以下为当前已发现量，候选 {0:N0} 个，共 {1}。部分分类被跳过或未读完，实际可清理量可能更多；这不是已释放空间。' -f [int64]$s.Scan.CandidateCount,(Format-SjcGuiSize ([int64]$s.Scan.CandidateBytes)))}
    if($App.FilesWindow){$App.FilesWindow.Title=if($filesOk){'文件明细 · {0:N0} 个候选{1}' -f [int64]$s.Scan.CandidateCount,$(if($partial){'（扫描不完整，已发现量）'}else{''})}else{'文件明细（已失效，需重新扫描）'}}
    $u.CleanButton.Style=$u.Window.FindResource($(if($cleanable -and -not $s.RecycleMode){'DangerButton'}elseif($cleanable){'PrimaryButton'}else{[Windows.Controls.Button]}))
    $u.CancelButton.Visibility=if($s.Busy){'Visible'}else{'Collapsed'}
    $u.CancelButton.IsEnabled=$s.Busy -and -not $App.Maintenance
    $u.BusyProgress.Visibility=if($s.Busy){'Visible'}else{'Collapsed'}
    $u.PreviousButton.IsEnabled=$idle -and $cleanable -and $s.PageOffset -gt 0
    $u.NextButton.IsEnabled=$idle -and $cleanable -and ($s.PageOffset+$s.PageSize) -lt $s.Scan.CandidateCount
    foreach($name in @('RemovePreviewButton')){$u[$name].IsEnabled=$idle}
    if($cleanable -or ($s.Scan -and -not $s.Stale)){
        $pending=[int64]$s.Scan.CandidateCount-$s.Excluded.Count
        $u.MetricBytes.Text=Format-SjcGuiSize $s.Scan.CandidateBytes;$u.MetricCount.Text=('{0:N0}' -f $s.Scan.CandidateCount);$u.MetricKept.Text=('{0:N0}' -f $s.Excluded.Count)
        $u.PendingText.Text=('将处理 {0:N0} 个未保留候选' -f $pending)
        $u.CleanButtonText.Text=('清理 {0:N0} 个…' -f $pending)
        $first=[math]::Min($s.PageOffset+1,[int64]$s.Scan.CandidateCount);$last=[math]::Min($s.PageOffset+$s.PageSize,[int64]$s.Scan.CandidateCount)
        $u.PageText.Text=('第 {0} / {1} 页  ·  {2:N0}–{3:N0} / {4:N0} 条  ·  每页 {5} 条' -f ([math]::Floor($s.PageOffset/$s.PageSize)+1),[math]::Max(1,[math]::Ceiling($s.Scan.CandidateCount/$s.PageSize)),$first,$last,$s.Scan.CandidateCount,$s.PageSize)
    }else{
        foreach($name in @('MetricBytes','MetricCount','MetricKept')){$u[$name].Text='—'}
        $u.PendingText.Text=if($s.Scan){'范围已变化，需重新扫描'}else{'尚未扫描'}
        $u.CleanButtonText.Text='清理…';$u.PageText.Text=''
    }
    $currentId=if($u.CandidatesList.SelectedItem){$u.CandidatesList.SelectedItem.Id}else{$null}
    $rows=@(Get-SjcGuiCandidateRows $s)
    $u.CandidatesList.ItemsSource=$rows
    if($currentId){$again=@($rows|Where-Object{$_.Id -eq $currentId});if($again.Count){$u.CandidatesList.SelectedItem=$again[0]}}
    $u.CandidatesEmpty.Visibility=if($rows.Count -eq 0){'Visible'}else{'Collapsed'}
    Update-SjcGuiFileChrome $App
    $selectedRules=@($u.CategoryList.SelectedItems|ForEach-Object RuleId)
    $categories=@(Get-SjcGuiCategoryRows $s)
    $u.CategoryList.ItemsSource=$categories
    # WPF 原生分组：默认视图按 Group 分组；分组标题不是数据项，不进入 SelectedItems。
    $view=[Windows.Data.CollectionViewSource]::GetDefaultView($u.CategoryList.ItemsSource)
    if($view -and $view.CanGroup -and $view.GroupDescriptions.Count -eq 0){$view.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Group'))}
    foreach($row in $categories){if($selectedRules -contains $row.RuleId){[void]$u.CategoryList.SelectedItems.Add($row)}}
    $u.CategoryEmpty.Visibility=if($categories.Count -eq 0){'Visible'}else{'Collapsed'}
    Update-SjcGuiCategoryButtons $App
    $historySelection=$u.HistoryList.SelectedItem
    $u.HistoryList.ItemsSource=@($s.History.ToArray())
    if($historySelection){$u.HistoryList.SelectedItem=$historySelection}
    $u.HistoryEmpty.Visibility=if($s.History.Count -eq 0){'Visible'}else{'Collapsed'}
    Update-SjcGuiProfile $App
    Set-SjcGuiStatus $App $s.Status
}
function Get-SjcGuiPartialReasonText {
    # 原因只取扫描结果本身：分类状态/说明、Warnings、Error。不估算、不编造释放空间。
    param($State)
    $scan=$State.Scan;$lines=New-Object 'System.Collections.Generic.List[string]'
    if($null -eq $scan){return '当前没有扫描结果。'}
    [void]$lines.Add(('扫描状态：{0}。当前已发现候选 {1:N0} 个，共 {2}。这是已发现量，不是已释放空间。' -f [string]$scan.Status,[int64]$scan.CandidateCount,(Format-SjcGuiSize ([int64]$scan.CandidateBytes))))
    [void]$lines.Add('')
    $map=Get-SjcGuiCategoryStatusMap;$abnormal=@(@($scan.Categories)|Where-Object{[string](Get-SjcGuiValue $_ 'Status' '') -ne 'Success'})
    [void]$lines.Add(('未完整扫描的分类（{0}）：' -f $abnormal.Count))
    foreach($category in $abnormal){$status=[string](Get-SjcGuiValue $category 'Status' '');$text=$map[$status];if(-not $text){$text=$status};$note=[string](Get-SjcGuiValue $category 'Note' '');[void]$lines.Add(('- [{0}] {1}：{2}{3}' -f [string](Get-SjcGuiValue $category 'Group' ''),[string](Get-SjcGuiValue $category 'Name' (Get-SjcGuiValue $category 'RuleId' '')),$text,$(if($note){'；'+$note}else{''})))}
    $warnings=@(Get-SjcGuiValue $scan 'Warnings' @())
    [void]$lines.Add('');[void]$lines.Add(('警告（{0} 条{1}）：' -f [int](Get-SjcGuiValue $scan 'WarningCount' $warnings.Count),$(if($warnings.Count){'，显示已记录部分'}else{''})))
    if($warnings.Count){foreach($warning in $warnings){[void]$lines.Add('- '+[string]$warning)}}else{[void]$lines.Add('- 无')}
    $errorText=[string](Get-SjcGuiValue $scan 'Error' '');if($errorText){[void]$lines.Add('');[void]$lines.Add('错误：'+$errorText)}
    $log=[string](Get-SjcGuiValue $scan 'LogPath' '');if($log){[void]$lines.Add('');[void]$lines.Add('日志：'+$log)}
    return ($lines -join "`r`n")
}
function New-SjcGuiAdvancedDraftWindow {
    # 模态草稿窗：独立勾选集合（HashSet），不触碰 State.Selected/CustomSelected；只有确定才由调用方一次提交。
    param($App)
    $s=$App.State
    $initial=if($s.CustomEnabled){@($s.CustomSelected)}else{@(Get-SjcGuiPresetIds $s.Context $s.Profile)}
    $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($id in $initial){if($s.RuleMap.ContainsKey([string]$id)){[void]$ids.Add([string]$id)}}
    $levelText=@{Low='低档起';Medium='中档起';High='高档起';CustomOnly='仅自定义'}
    $rows=@($s.Rules|ForEach-Object{$level=[string](Get-SjcGuiValue $_ 'PresetLevel' '');$lt=$levelText[$level];if(-not $lt){$lt=$level};$group=[string]$_.Group;if(-not $group){$group='未分组'}
        [pscustomobject]@{Id=[string]$_.Id;Name=[string]$_.Name;Group=$group;LevelText=$lt;AgeText=('≥ '+[string]$_.MinimumAgeHours+' 小时');Selected=$ids.Contains([string]$_.Id);Detail=([string]$_.Note+"`r`n"+[string]$_.Root+"`r`n"+$(if($_.Available){'目录存在'}else{'目录不存在，扫描时跳过'}))}})
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="高级自定义规则" Width="680" Height="580" MinWidth="520" MinHeight="420" Background="White" FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#16213A" ShowInTaskbar="False" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
 <DockPanel Margin="16,14,16,12">
  <TextBlock DockPanel.Dock="Top" Text="高级自定义：逐条选择规则" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,4"/>
  <TextBlock x:Name="DraftHint" DockPanel.Dock="Top" Foreground="#6B7890" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8"/>
  <StackPanel DockPanel.Dock="Top" Orientation="Horizontal"><Button x:Name="DiscoverButton" Style="{DynamicResource SmallButton}" Content="发现缓存位置…"/><Button x:Name="MaintenanceButton" Style="{DynamicResource SmallButton}" Content="系统维护…"/></StackPanel>
  <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
   <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
    <Button x:Name="DraftCancel" IsCancel="True" MinWidth="96" Margin="0,0,8,0"><TextBlock Text="取消"/></Button>
    <Button x:Name="DraftAccept" Style="{DynamicResource PrimaryButton}" MinWidth="96" Margin="0"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:CheckPage}" Style="{DynamicResource Glyph}" FontSize="12" Margin="0,0,6,0"/><TextBlock Text="确定"/></StackPanel></Button>
   </StackPanel>
   <WrapPanel VerticalAlignment="Center">
    <Button x:Name="DraftReset" Style="{DynamicResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Reset}" Style="{DynamicResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="恢复为当前预设"/></StackPanel></Button>
    <Button x:Name="DraftAll" Style="{DynamicResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:CheckPage}" Style="{DynamicResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="全选"/></StackPanel></Button>
    <Button x:Name="DraftNone" Style="{DynamicResource SmallButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:ClearSelection}" Style="{DynamicResource Glyph}" FontSize="12" Margin="0,0,5,0"/><TextBlock Text="全不选"/></StackPanel></Button>
    <TextBlock x:Name="DraftCount" Foreground="#3D4A63" FontSize="12" VerticalAlignment="Center" Margin="4,0,0,6"/>
   </WrapPanel>
  </DockPanel>
  <ListBox x:Name="DraftList" BorderBrush="#E6EBF3" BorderThickness="1" ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.IsVirtualizingWhenGrouping="True" ScrollViewer.CanContentScroll="True" AutomationProperties.Name="自定义规则草稿列表">
   <ListBox.GroupStyle><GroupStyle><GroupStyle.HeaderTemplate><DataTemplate><Border Background="#F7F9FD" BorderBrush="#E6EBF3" BorderThickness="0,0,0,1" Padding="8,4"><TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="#1C3F9E" FontSize="12"/></Border></DataTemplate></GroupStyle.HeaderTemplate></GroupStyle></ListBox.GroupStyle>
   <ListBox.ItemContainerStyle><Style TargetType="ListBoxItem"><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Padding" Value="8,0"/><Setter Property="MinHeight" Value="28"/><Setter Property="AutomationProperties.Name" Value="{Binding Name}"/></Style></ListBox.ItemContainerStyle>
   <ListBox.ItemTemplate><DataTemplate><Grid ToolTip="{Binding Detail}"><Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
    <CheckBox IsChecked="{Binding Selected,Mode=OneWay}" VerticalAlignment="Center" AutomationProperties.Name="{Binding Name}"/>
    <TextBlock Grid.Column="1" Text="{Binding Name}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="2" Text="{Binding LevelText}" Foreground="#6B7890" FontSize="12" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="3" Text="{Binding AgeText}" Foreground="#6B7890" FontSize="12" VerticalAlignment="Center"/>
   </Grid></DataTemplate></ListBox.ItemTemplate>
  </ListBox>
 </DockPanel>
</Window>
'@
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new((Expand-SjcGuiGlyphs $xaml)))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    [void]$window.Resources.MergedDictionaries.Add($App.Ui.Window.Resources)
    if($App.Ui.Window.Icon){$window.Icon=$App.Ui.Window.Icon}
    $draft=@{App=$App;Window=$window;Ids=$ids;Rows=$rows;Accepted=$false;List=$window.FindName('DraftList');Count=$window.FindName('DraftCount');Accept=$window.FindName('DraftAccept')}
    $window.Tag=$draft
    $window.FindName('MaintenanceButton').Tag=$draft
    $window.FindName('MaintenanceButton').Add_Click({param($sender,$event) Show-SjcGuiMaintenance $sender.Tag})
    $window.FindName('DiscoverButton').Tag=$draft
    $window.FindName('DiscoverButton').Add_Click({param($sender,$event) Show-SjcGuiDiscovery $sender.Tag})
    $window.FindName('DraftHint').Text=('基于{0}。勾选只改草稿；点“确定”才应用并使旧扫描失效，集合未变化则保留当前扫描。取消或关闭不改变范围。仅本次会话有效，下次启动恢复预设。' -f (Get-SjcGuiProfileLabel $s.Profile))
    $draft.List.ItemsSource=$rows
    $view=[Windows.Data.CollectionViewSource]::GetDefaultView($draft.List.ItemsSource)
    if($view -and $view.CanGroup){$view.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Group'))}
    $draft.List.Tag=$draft
    $toggle=[Windows.RoutedEventHandler]{param($sender,$event) $box=$event.OriginalSource;if($box -isnot [Windows.Controls.CheckBox]){return};$row=$box.DataContext;if($null -eq $row -or -not $row.PSObject.Properties['Id']){return};$d=$sender.Tag;$want=[bool]$box.IsChecked;if($want){[void]$d.Ids.Add($row.Id)}else{[void]$d.Ids.Remove($row.Id)};$row.Selected=$want;Update-SjcGuiAdvancedDraft $d}
    $draft.List.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,$toggle)
    $draft.List.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,$toggle)
    foreach($pair in @(@('DraftReset','Reset'),@('DraftAll','All'),@('DraftNone','None'))){$button=$window.FindName($pair[0]);$button.Tag=@{Draft=$draft;Kind=$pair[1]};$button.Add_Click({param($sender,$event) Set-SjcGuiAdvancedDraftIds $sender.Tag.Draft $sender.Tag.Kind})}
    $draft.Accept.Tag=$draft
    $draft.Accept.Add_Click({param($sender,$event) $d=$sender.Tag;if($d.Ids.Count -eq 0){return};$d.Accepted=$true;$d.Window.DialogResult=$true})
    foreach($pair in @(@('DraftReset','恢复为当前预设'),@('DraftAll','全选'),@('DraftNone','全不选'),@('DraftAccept','确定应用自定义规则'),@('DraftCancel','取消，不改变范围'))){[Windows.Automation.AutomationProperties]::SetName($window.FindName($pair[0]),$pair[1])}
    Update-SjcGuiAdvancedDraft $draft
    return $window
}
function New-SjcGuiMaintenanceWindow {
    param($Draft)
    $w=[Windows.Window]::new();$w.Title='系统维护';$w.Width=570;$w.Height=340;$w.Owner=$Draft.Window;$w.WindowStartupLocation='CenterOwner';$w.ShowInTaskbar=$false
    [void]$w.Resources.MergedDictionaries.Add($Draft.App.Ui.Window.Resources);if($Draft.Window.Icon){$w.Icon=$Draft.Window.Icon}
    $panel=[Windows.Controls.StackPanel]::new();$panel.Margin='18';$w.Content=$panel
    $text=[Windows.Controls.TextBlock]::new();$text.TextWrapping='Wrap';$text.Text="Windows 组件存储清理需要管理员权限，将请求 UAC。旧组件可能立即删除，没有 30 天缓冲，可能影响更新回滚；不使用 ResetBase。运行可能需要很长时间，无法准确预估释放空间。不会自动重试、强制终止或限时。";$panel.Children.Add($text)|Out-Null
    $status=[Windows.Controls.TextBlock]::new();$status.Margin='0,16,0,10';$status.TextWrapping='Wrap';$status.Text='尚未启动。';$panel.Children.Add($status)|Out-Null
    $button=[Windows.Controls.Button]::new();$button.Content='确认并启动组件清理…';$button.HorizontalAlignment='Left';$panel.Children.Add($button)|Out-Null
    $w.Tag=@{Draft=$Draft;Status=$status;Button=$button};$button.Tag=$w.Tag
    $button.Add_Click({param($sender,$event) $d=$sender.Tag.Draft;$app=$d.App;$s=$app.State;if($s.Busy -or $app.Maintenance){return};if($s.TestMode){$sender.Tag.Status.Text='测试模式禁止启动。';return};if([Windows.MessageBox]::Show($d.Window,'将以管理员权限运行组件清理，旧组件可能立即删除并影响回滚。确认继续？','确认系统维护','YesNo','Warning','No') -ne 'Yes'){return};$r=Start-SjcMaintenance -ActionId 'ComponentCleanup';if($r.Status -ne 'Running'){$sender.Tag.Status.Text=($r.Status+'：'+$r.Error);return};$app.Maintenance=@{Process=$r.Process;View=$sender.Tag};$s.Busy=$true;$sender.IsEnabled=$false;$sender.Tag.Status.Text='系统维护进行中；关闭此窗口不会停止维护。';Set-SjcGuiStatus $app '系统维护进行中，扫描和清理已暂停。';Update-SjcGuiView $app})
    $w.Add_Closing({param($sender,$event) $app=$sender.Tag.Draft.App;if($app.Maintenance){if([Windows.MessageBox]::Show($sender,'维护将继续运行，主窗口会显示结果。确定关闭此窗口？','系统维护','YesNo','Information','No') -ne 'Yes'){$event.Cancel=$true}else{$app.Maintenance.View=$null}}})
    return $w
}
function Show-SjcGuiMaintenance {
    param($Draft)
    $w=New-SjcGuiMaintenanceWindow $Draft;[void]$w.ShowDialog()
}
function Invoke-SjcGuiMaintenanceTick {
    param($App)
    $m=$App.Maintenance;if(-not $m){return}
    $exited=$false;$message=''
    try{
        if($m.Process.HasExited){
            $exited=$true;$code=$m.Process.ExitCode
            if($code -eq 0){$message="系统维护 Success,退出代码 0；实际释放空间未知。"}
            elseif($code -eq 3010){$message="系统维护 RebootRequired,退出代码 3010；操作已完成但需要重启后生效,不会自动重启；实际释放空间未知。"}
            else{$message="系统维护 Failed,退出代码 $code；实际释放空间未知。"}
        }
    }catch{$exited=$true;$message='系统维护结果 Unknown：无法读取进程退出状态,实际释放空间未知。'}
    if(-not $exited){return}
    # 先清运行状态再更新界面：View/状态栏更新抛异常也不会残留 Busy/Maintenance；不 Kill 维护进程,仅释放句柄。
    $App.Maintenance=$null;$App.State.Busy=$false
    try{$m.Process.Dispose()}catch{}
    try{if($m.View){$m.View.Status.Text=$message;$m.View.Button.IsEnabled=$true}}catch{}
    try{Set-SjcGuiStatus $App $message}catch{}
    Update-SjcGuiView $App
}
function New-SjcGuiDiscoveryWindow {
    param($Draft)
    $w=[Windows.Window]::new();$w.Title='发现缓存位置';$w.Width=760;$w.Height=500;$w.Owner=$Draft.Window;$w.WindowStartupLocation='CenterOwner';$w.ShowInTaskbar=$false
    [void]$w.Resources.MergedDictionaries.Add($Draft.App.Ui.Window.Resources);if($Draft.Window.Icon){$w.Icon=$Draft.Window.Icon}
    $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='14';$w.Content=$dock
    $hint=[Windows.Controls.TextBlock]::new();$hint.Text='仅显示引擎发现的候选；选择一项后可授权或撤销。授权不等于清理。';$hint.TextWrapping='Wrap';[Windows.Controls.DockPanel]::SetDock($hint,'Top');$dock.Children.Add($hint)|Out-Null
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';[Windows.Controls.DockPanel]::SetDock($buttons,'Bottom');$dock.Children.Add($buttons)|Out-Null
    $list=[Windows.Controls.ListBox]::new();$list.Margin='0,10,0,10';$dock.Children.Add($list)|Out-Null
    $w.Tag=@{Draft=$Draft;List=$list;Window=$w}
    foreach($pair in @(@('授权所选','Approve'),@('撤销所选','Revoke'))){$b=[Windows.Controls.Button]::new();$b.Content=$pair[0];$b.Margin='0,0,8,0';$b.Tag=@{View=$w.Tag;Action=$pair[1]};$buttons.Children.Add($b)|Out-Null;$b.Add_Click({param($sender,$event) Invoke-SjcGuiDiscoveryChange $sender.Tag.View $sender.Tag.Action});if($pair[1] -eq 'Approve'){$w.Tag.ApproveButton=$b;$b.IsEnabled=$false}}
    $list.Tag=$w.Tag;$list.Add_SelectionChanged({param($sender,$event) $entry=$sender.SelectedItem;$sender.Tag.ApproveButton.IsEnabled=($null -ne $entry -and [bool]$entry.Tag.Supported -and (-not [bool]$entry.Tag.Authorized -or [string](Get-SjcGuiValue $entry.Tag 'Status' '') -ceq 'StaleAuthorization') -and -not [string]::IsNullOrWhiteSpace([string](Get-SjcGuiValue $entry.Tag 'Binding' '')))})
    foreach($item in @(Get-SjcDiscoveredCacheLocations -Context $Draft.App.State.Context)){$entry=[Windows.Controls.ListBoxItem]::new();$entry.Tag=$item;$entry.Content=('{0} | {1} | {2} | 支持 {3} | 已授权 {4}' -f $item.Application,$item.Source,$item.Root,$item.Supported,$item.Authorized)+"`r`n"+([string]$item.Status)+'  '+([string]$item.Note);$list.Items.Add($entry)|Out-Null}
    return $w
}
function Show-SjcGuiDiscovery {
    param($Draft)
    try{$w=New-SjcGuiDiscoveryWindow $Draft;[void]$w.ShowDialog()}catch{[void][Windows.MessageBox]::Show($Draft.Window,('无法读取发现候选：'+$_.Exception.Message),'发现缓存位置')}
}
function Invoke-SjcGuiDiscoveryChange {
    param($View,[string]$Action)
    $app=$View.Draft.App;$s=$app.State;$entry=$View.List.SelectedItem;if(-not $entry -or $s.Busy -or $s.PendingScope){return};$item=$entry.Tag
    if($Action -eq 'Approve'){
        # 受支持失效条目(Supported=true, Status=StaleAuthorization, Authorized=true)允许用当前 Binding 重新确认；当前 Authorized 状态不得重复直接授权。
        if(-not $item.Supported -or ([string](Get-SjcGuiValue $item 'Status' '') -cne 'StaleAuthorization' -and $item.Authorized)){return}
        if([string]::IsNullOrWhiteSpace([string](Get-SjcGuiValue $item 'Binding' ''))){[void][Windows.MessageBox]::Show($View.Window,'候选缺少目录身份绑定,不能授权；请刷新发现结果后重试。');return}
    }
    if($Action -eq 'Revoke' -and -not $item.Authorized -and [string]::IsNullOrWhiteSpace([string](Get-SjcGuiValue $item 'AuthorizationId' '')) -and [string](Get-SjcGuiValue $item 'Status' '') -cne 'StaleAuthorization'){return}
    if($s.TestMode){return}
    $verb=if($Action -eq 'Approve'){'授权'}else{'撤销授权'}
    $question="$verb 此引擎发现的缓存位置？`r`n应用：$($item.Application)`r`n来源：$($item.Source)`r`n精确路径：$($item.Root)`r`n影响：$($item.Note)`r`n授权变化将使旧扫描失效,需重新打开高级草稿。"
    if([Windows.MessageBox]::Show($View.Window,$question,'确认授权变化','YesNo','Warning','No') -ne 'Yes'){return}
    if(Test-SjcGuiPreviewOpen $s){Start-SjcGuiLocalJob $app 'Close' @{};Set-SjcGuiStatus $app '正在释放旧预览,请完成后重新操作授权。';[void][Windows.MessageBox]::Show($View.Window,'正在释放旧预览,请稍后再次确认。');return}
    try{
        Clear-SjcGuiScan $app
        if($Action -eq 'Approve'){$null=Approve-SjcCacheLocations -Context $s.Context -Ids ([string[]]@($item.Id)) -ExpectedBindings ([string[]]@($item.Binding))}else{$null=Revoke-SjcCacheLocations -Context $s.Context -Ids ([string[]]@($item.Id))}
        $s.Rules=@(Refresh-SjcAuthorizedRules -Context $s.Context);$s.RuleMap=@{};foreach($rule in $s.Rules){$s.RuleMap[[string]$rule.Id]=$rule}
        $s.CustomEnabled=$false;$s.CustomSelected.Clear();$s.Selected.Clear();foreach($id in @(Get-SjcGuiPresetIds $s.Context $s.Profile)){[void]$s.Selected.Add($id)}
        Update-SjcGuiRuleRows $app;Update-SjcGuiView $app
        $View.Draft.AuthorizationChanged=$true;$View.Window.Close();$View.Draft.Window.Close()
        [void][Windows.MessageBox]::Show($app.Ui.Window,'授权已变化,旧扫描和高级草稿已失效。请重新打开高级规则。')
    }catch{Clear-SjcGuiScan $app;$s.ProfileSupported=$false;Update-SjcGuiView $app;$View.Draft.AuthorizationChanged=$true;[void][Windows.MessageBox]::Show($View.Window,('授权或规则刷新失败,旧扫描已失效；请重启程序后重试：'+$_.Exception.Message));$View.Window.Close();$View.Draft.Window.Close()}
}
function Set-SjcGuiAdvancedDraftIds {
    param($Draft,[ValidateSet('Reset','All','None')][string]$Kind)
    $s=$Draft.App.State
    $Draft.Ids.Clear()
    $source=switch($Kind){'Reset'{@(Get-SjcGuiPresetIds $s.Context $s.Profile)}'All'{@($s.Rules|ForEach-Object{[string]$_.Id})}default{@()}}
    foreach($id in $source){[void]$Draft.Ids.Add([string]$id)}
    foreach($row in $Draft.Rows){$row.Selected=$Draft.Ids.Contains($row.Id)}
    $Draft.List.Items.Refresh()
    Update-SjcGuiAdvancedDraft $Draft
}
function Update-SjcGuiAdvancedDraft {
    param($Draft)
    $Draft.Count.Text=('草稿已选 {0} / {1} 条' -f $Draft.Ids.Count,@($Draft.Rows).Count)
    $Draft.Accept.IsEnabled=($Draft.Ids.Count -gt 0)
}
function Get-SjcGuiAdvancedDraftIds {
    param($Draft)
    return [string[]]@($Draft.App.State.Rules|Where-Object{$Draft.Ids.Contains([string]$_.Id)}|ForEach-Object{[string]$_.Id})
}
function Confirm-SjcGuiAdvancedDraft {
    # 确定：实际集合未变化则保留当前模式与扫描；否则一次应用自定义范围。
    param($App,[string[]]$Ids)
    $s=$App.State
    $ordered=[string[]]@($s.Rules|Where-Object{$Ids -ccontains [string]$_.Id}|ForEach-Object{[string]$_.Id})
    if($ordered.Count -eq 0){throw '至少选择一条规则。'}
    if(Test-SjcGuiSameIds $ordered @(Get-SjcGuiEffectiveRuleIds $s)){Set-SjcGuiStatus $App '清理范围未变化，保留当前模式与扫描结果。';return $false}
    Request-SjcGuiScope $App @{Profile=$s.Profile;CustomEnabled=$true;CustomIds=$ordered}
    return $true
}
function Show-SjcGuiAdvancedDraft {
    param($App)
    $s=$App.State
    if($s.Busy -or $s.PendingScope){throw '请等待当前任务结束后再调整范围。'}
    $window=New-SjcGuiAdvancedDraftWindow $App
    $window.Owner=$App.Ui.Window;$window.WindowStartupLocation='CenterOwner'
    $accepted=[bool]$window.ShowDialog() -and $window.Tag.Accepted
    if(-not $accepted){if($window.Tag.AuthorizationChanged){Set-SjcGuiStatus $App '授权已变化，请重新打开高级规则并重新扫描。'}else{Set-SjcGuiStatus $App '已关闭高级自定义草稿，范围未改变。'};return}
    try{[void](Confirm-SjcGuiAdvancedDraft $App (Get-SjcGuiAdvancedDraftIds $window.Tag))}
    catch{Set-SjcGuiStatus $App ('未应用高级自定义：'+$_.Exception.Message);Update-SjcGuiView $App}
}
function Show-SjcGuiDetails {
    param($App,[string]$Text,[string]$Title='任务详情')
    $window=[Windows.Window]::new();$window.Title=$Title;$window.Width=760;$window.Height=480;$window.Owner=$App.Ui.Window;$window.WindowStartupLocation='CenterOwner'
    if($App.Ui.Window.Icon){$window.Icon=$App.Ui.Window.Icon}
    $box=[Windows.Controls.TextBox]::new();$box.IsReadOnly=$true;$box.TextWrapping='Wrap';$box.VerticalScrollBarVisibility='Auto';$box.Text=$Text;$box.Padding='14';$window.Content=$box
    [void]$window.ShowDialog()
}
function Confirm-SjcGui {
    param($App,[string]$Text)
    if($App.State.TestMode){return $false}
    return ([Windows.MessageBox]::Show($App.Ui.Window,$Text,'请确认','YesNo','Warning','No') -eq 'Yes')
}
function Get-SjcGuiCleanSummary {
    # 清理范围 = 扫描封存的全部未保留候选；档位与自定义模式取扫描结果，而不是当前控件。
    param($State)
    $s=$State
    $keptCount=@{};$keptBytes=@{}
    foreach($id in @($s.Excluded.Keys)){$rule=[string]$s.ExcludedRule[$id];$keptCount[$rule]=1+[int64]$keptCount[$rule];$keptBytes[$rule]=[int64]$keptBytes[$rule]+[int64]$s.Excluded[$id]}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($category in @($s.Scan.Categories)){
        $ruleId=[string](Get-SjcGuiValue $category 'RuleId' '')
        $count=[int64](Get-SjcGuiValue $category 'Count' 0)
        if($count -le 0){continue}
        $pendingCount=$count-[int64]$keptCount[$ruleId];$pendingBytes=[int64](Get-SjcGuiValue $category 'Bytes' 0)-[int64]$keptBytes[$ruleId]
        if($pendingCount -le 0){continue}
        $rule=if($s.RuleMap.ContainsKey($ruleId)){$s.RuleMap[$ruleId]}else{$null}
        $note=[string](Get-SjcGuiValue $category 'Note' '');if(-not $note -and $rule){$note=[string]$rule.Note}
        $risk=[string](Get-SjcGuiValue $category 'Risk' '');if(-not $risk -and $rule){$risk=[string]$rule.Risk}
        $group=[string](Get-SjcGuiValue $category 'Group' '');if(-not $group -and $rule){$group=[string]$rule.Group}
        $root=[string](Get-SjcGuiValue $category 'Root' '');if(-not $root -and $rule){$root=[string]$rule.Root}
        [void]$rows.Add([pscustomobject]@{Group=$group;RuleId=$ruleId;Name=[string](Get-SjcGuiValue $category 'Name' $ruleId);Root=$root;Count=$pendingCount;CountText=('{0:N0}' -f $pendingCount);Bytes=$pendingBytes;SizeText=(Format-SjcGuiSize $pendingBytes);Kept=[int64]$keptCount[$ruleId];Impact=$(if($note){'风险 '+$risk+'；'+$note}else{'风险 '+$risk})})
    }
    $profile=[string](Get-SjcGuiValue $s.Scan 'CleaningProfile' $s.ScanProfile)
    if(-not $profile){$profile=$s.ScanProfile}
    $profile=Assert-SjcGuiProfileValue $profile
    $custom=Get-SjcGuiValue $s.Scan 'CustomEnabled' $s.ScanCustomEnabled
    $info=Get-SjcGuiProfileInfo $profile
    $pending=[int64]$s.Scan.CandidateCount-$s.Excluded.Count
    $bytes=[int64]$s.Scan.CandidateBytes-(Get-SjcGuiExcludedBytes $s)
    return [pscustomobject]@{PendingCount=$pending;PendingBytes=$bytes;KeptCount=$s.Excluded.Count;CheckedCount=$s.CandidateSelection.Count;RecycleMode=[bool]$s.RecycleMode;Profile=$profile;ProfileLabel=[string]$info.Label;CustomEnabled=[bool]$custom;Impact=[string]$info.Impact;HighImpact=($profile -ceq 'High');ProfileSupported=[bool]$s.ProfileSupported;Rows=$rows.ToArray()}
}
function New-SjcGuiCleanConfirmWindow {
    param($App,$Summary)
    $mode=if($Summary.RecycleMode){'移入回收站：可从回收站还原；通常不会立即释放磁盘空间。'}else{'永久删除：不经过回收站，无法从回收站恢复。'}
    $profile=$Summary.ProfileLabel+'（扫描时封存'+$(if($Summary.CustomEnabled){'，高级自定义范围'}else{'预设'})+'）'
    $checkedNote=if($Summary.CheckedCount){'勾选的 '+$Summary.CheckedCount+' 个文件只用于保留/复制等批量操作，不限定清理范围。'}else{'清理范围不取决于勾选。'}
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="确认清理范围" Width="880" Height="560" MinWidth="720" MinHeight="420" WindowStartupLocation="CenterOwner" FontFamily="Microsoft YaHei UI" FontSize="13" Background="White" Foreground="#16213A" ShowInTaskbar="False" UseLayoutRounding="True">
 <Border Padding="18"><DockPanel>
  <StackPanel DockPanel.Dock="Top">
   <TextBlock x:Name="Headline" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
   <Grid Margin="0,10,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
    <TextBlock Text="处理方式" Foreground="#6B7890"/><TextBlock x:Name="ModeText" Grid.Column="1" TextWrapping="Wrap" FontWeight="Medium"/>
    <TextBlock Grid.Row="1" Text="清理强度" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="ProfileText" Grid.Row="1" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <TextBlock Grid.Row="2" Text="保留" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="KeptText" Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <TextBlock Grid.Row="3" Text="勾选" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="CheckedText" Grid.Row="3" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <TextBlock Grid.Row="4" Text="影响" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="ImpactText" Grid.Row="4" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
   </Grid>
  </StackPanel>
  <StackPanel DockPanel.Dock="Bottom">
   <TextBlock Text="清理时逐个重新核对规则、路径、链接、大小、修改时间和文件身份；变化、占用或只读的文件会跳过。" Foreground="#6B7890" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,10"/>
   <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="CancelConfirm" Content="取消" IsCancel="True" IsDefault="True" MinWidth="96" MinHeight="32" Padding="14,4" Margin="0,0,8,0"/><Button x:Name="AcceptConfirm" MinWidth="96" MinHeight="32" Padding="14,4" Foreground="White" BorderThickness="0"/></StackPanel>
  </StackPanel>
  <ListView x:Name="ScopeTable" BorderBrush="#E6EBF3" BorderThickness="1" VirtualizingPanel.IsVirtualizing="True" ScrollViewer.HorizontalScrollBarVisibility="Auto" AutomationProperties.Name="清理范围明细">
   <ListView.ItemContainerStyle><Style TargetType="ListViewItem"><Setter Property="MinHeight" Value="30"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style></ListView.ItemContainerStyle>
   <ListView.View><GridView>
    <GridViewColumn Header="类别" Width="80"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Group}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
    <GridViewColumn Header="规则" Width="150"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Name}" ToolTip="{Binding Name}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
    <GridViewColumn Header="路径" Width="200"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Root}" ToolTip="{Binding Root}" TextTrimming="CharacterEllipsis" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="11" Foreground="#6B7890"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
    <GridViewColumn Header="数量" Width="64"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CountText}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
    <GridViewColumn Header="大小" Width="84"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding SizeText}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
    <GridViewColumn Header="影响" Width="200"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Impact}" ToolTip="{Binding Impact}" TextTrimming="CharacterEllipsis" Foreground="#3D4A63"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
   </GridView></ListView.View>
  </ListView>
 </DockPanel></Border>
</Window>
'@
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($xaml))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    if($App -and $App.Ui.Window.Icon){$window.Icon=$App.Ui.Window.Icon}
    $window.FindName('Headline').Text=('将处理全部未保留候选 {0:N0} 个，共 {1}（{2} 条规则）' -f $Summary.PendingCount,(Format-SjcGuiSize $Summary.PendingBytes),@($Summary.Rows).Count)
    $window.FindName('ModeText').Text=$mode
    $window.FindName('ProfileText').Text=$profile
    $window.FindName('KeptText').Text=('{0:N0} 个已保留文件不处理。' -f $Summary.KeptCount)
    $window.FindName('CheckedText').Text=$checkedNote
    $impact=$window.FindName('ImpactText');$impact.Text=$Summary.Impact;if($Summary.HighImpact){$impact.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#9A4F06');$impact.FontWeight='SemiBold'}
    $window.FindName('ScopeTable').ItemsSource=@($Summary.Rows)
    $accept=$window.FindName('AcceptConfirm')
    $accept.Content=if($Summary.RecycleMode){'移入回收站'}else{'永久删除'}
    $accept.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Summary.RecycleMode){'#2F6BFF'}else{'#C2342B'}))
    $accept.Tag=$window
    $accept.Add_Click({param($sender,$event) $sender.Tag.DialogResult=$true})
    return $window
}
function Initialize-SjcGuiBackground {
    param($App)
    if($App.State.Background){return}
    $initial=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $initial.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('SjcEmbeddedVersion',(Get-SjcVersionInfo),''))
    foreach($command in Get-Command -CommandType Function | Where-Object Name -Match '-Sjc'){
        $initial.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($command.Name,$command.Definition))
    }
    $initial.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('SjcContexts',(Get-SjcRegistry),''))
    $sandboxes=Get-Variable -Scope Script -Name SjcSandboxes -ValueOnly -ErrorAction SilentlyContinue
    if($sandboxes){$initial.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('SjcSandboxes',$sandboxes,''))}
    $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initial);$runspace.ApartmentState='MTA';$runspace.Open()
    $App.State.Background=@{Runspace=$runspace;Shared=@{Preview=$null}}
}
function Start-SjcGuiLocalJob {
    param($App,[ValidateSet('Open','Page','RuleKeep','Export','Close')][string]$Kind,$Arguments)
    if($App.State.LocalJob){throw '已有候选操作正在执行。'}
    Initialize-SjcGuiBackground $App
    $background=$App.State.Background
    $source=@'
param($Shared,$Kind,$Arguments,$Token)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
switch($Kind){
 'Open' { if($Shared.Preview){Close-SjcPreviewSession $Shared.Preview};$Shared.Preview=Open-SjcPreviewSession -PlanPath $Arguments.PlanPath -CancellationToken $Token;[pscustomobject]@{Items=@(Get-SjcPreviewPage $Shared.Preview -Offset 0 -Limit 200);Count=$Shared.Preview.Count} }
 'Page' { $Token.ThrowIfCancellationRequested();[pscustomobject]@{Items=@(Get-SjcPreviewPage $Shared.Preview -Offset $Arguments.Offset -Limit 200)} }
 'RuleKeep' { $list=New-Object 'System.Collections.Generic.List[object]';$ids=if($Arguments.ContainsKey('RuleIds')){@($Arguments.RuleIds)}else{@($Arguments.RuleId)};foreach($rid in $ids){$Token.ThrowIfCancellationRequested();foreach($item in @(Get-SjcPreviewRuleCandidates $Shared.Preview $rid)){[void]$list.Add([pscustomobject]@{Id=$item.Id;Length=[int64]$item.Length;RuleId=[string]$rid})}};[pscustomobject]@{Items=$list.ToArray()} }
 'Export' { $Token.ThrowIfCancellationRequested();Export-SjcCandidates -PlanPath $Arguments.PlanPath -Destination $Arguments.Destination -ExcludedIds $Arguments.ExcludedIds -CancellationToken $Token }
 'Close' { if($Shared.Preview){Close-SjcPreviewSession $Shared.Preview;$Shared.Preview=$null};[pscustomobject]@{Closed=$true} }
}
'@
    $power=[PowerShell]::Create();$power.Runspace=$background.Runspace
    $cancel=[Threading.CancellationTokenSource]::new()
    [void]$power.AddScript($source).AddArgument($background.Shared).AddArgument($Kind).AddArgument($Arguments).AddArgument($cancel.Token)
    $handle=$power.BeginInvoke()
    $App.State.LocalJob=@{Kind=$Kind;Arguments=$Arguments;PowerShell=$power;Handle=$handle;Cancel=$cancel}
    $label=@{Open='打开候选预览';Page='读取分页';RuleKeep='按分类更新保留';Export='完整导出 CSV';Close='释放旧预览'}[$Kind]
    $App.State.Busy=$true;Set-SjcGuiStatus $App ('正在后台'+$label+'；完成前范围与清理操作暂停。');Update-SjcGuiView $App
}
function Confirm-SjcGuiClean {
    # 先确认全部未保留范围与扫描真实档位；永久删除再单独确认一次。
    param($App,$Summary)
    if($App.State.TestMode){return $false}
    $window=New-SjcGuiCleanConfirmWindow $App $Summary
    $window.Owner=$App.Ui.Window
    if(-not [bool]$window.ShowDialog()){return $false}
    if(-not $Summary.RecycleMode){
        $text=('永久删除 {0:N0} 个文件（{1}），不经过回收站，无法从回收站恢复。确定永久删除？' -f $Summary.PendingCount,(Format-SjcGuiSize $Summary.PendingBytes))
        return ([Windows.MessageBox]::Show($App.Ui.Window,$text,'再次确认永久删除','YesNo','Warning','No') -eq 'Yes')
    }
    return $true
}
function New-SjcGuiTaskPayload {
    # Scan/Clean 载荷必须显式包含 CleaningProfile 与布尔 CustomEnabled。
    # Scan 的 RuleIds 是实际集合（预设时精确等于引擎预设）；Clean 的档位/自定义取扫描封存结果。
    param($State,[ValidateSet('Scan','Clean','Recycle')][string]$Action,[string]$Task,[string]$Progress,[string]$Cancel)
    $s=$State
    $payload=[ordered]@{TaskDirectory=$Task;ProgressPath=$Progress;CancelPath=$Cancel}
    if($Action -eq 'Scan'){
        $ids=[string[]]@(Get-SjcGuiEffectiveRuleIds $s)
        if($ids.Count -eq 0){throw '当前范围没有规则，不能扫描。'}
        $payload.RuleIds=$ids
        $payload.CleaningProfile=Assert-SjcGuiProfileValue $s.Profile
        $payload.CustomEnabled=[bool]$s.CustomEnabled
    }
    if($Action -eq 'Clean'){
        $profile=Assert-SjcGuiProfileValue ([string](Get-SjcGuiValue $s.Scan 'CleaningProfile' $s.ScanProfile))
        $custom=Get-SjcGuiValue $s.Scan 'CustomEnabled' $s.ScanCustomEnabled
        if($custom -isnot [bool]){throw '扫描结果缺少自定义模式，请重新扫描。'}
        if($profile -cne $s.Profile -or $custom -ne $s.CustomEnabled){throw '扫描后范围已变化，请重新扫描。'}
        $payload.ExcludedIds=[string[]]@($s.Excluded.Keys);$payload.RecycleMode=[bool]$s.RecycleMode
        $payload.CleaningProfile=$profile
        $payload.CustomEnabled=[bool]$custom
    }
    return $payload
}
function Start-SjcGuiTask {
    param($App,[ValidateSet('Scan','Clean','Recycle')][string]$Action)
    $s=$App.State
    if($s.Busy){throw '已有任务正在运行。'}
    if($s.TestMode){throw '隔离界面模式不允许启动生产 Worker。'}
    if($s.PendingScope){throw '范围调整尚未完成。'}
    if($Action -in @('Scan','Clean') -and (Get-SjcGuiContextProfile $s.Context) -cne $s.Profile){throw '界面强度与引擎上下文不一致，请重新选择强度。'}
    if($Action -eq 'Clean'){if(-not (Test-SjcGuiCleanable $s)){throw '没有可清理的有效扫描。'};$task=$s.TaskDirectory}else{$task=New-SjcTaskDirectory $s.Context}
    $id=[guid]::NewGuid().ToString('N').Substring(0,8);$prefix='gui-'+$Action.ToLower()+'-'+$id
    $payloadPath=Join-Path $task ($prefix+'.payload.json');$outputPath=Join-Path $task ($prefix+'.output.json');$progress=Join-Path $task ($prefix+'.progress.json');$cancel=Join-Path $task ($prefix+'.cancel')
    $payload=New-SjcGuiTaskPayload $s $Action $task $progress $cancel
    Write-SjcAtomicText $payloadPath ($payload|ConvertTo-Json -Depth 5 -Compress) -NoOverwrite
    $spec=Get-SjcGuiLaunchSpec $Action $payloadPath $outputPath
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$spec.FileName;$info.Arguments=$spec.Arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try{if(-not $process.Start()){throw '无法启动后台进程。'}}catch{$process.Dispose();throw}
    $s.Task=@{Action=$Action;TaskDirectory=$task;Process=$process;OutputPath=$outputPath;ProgressPath=$progress;CancelPath=$cancel;CancelRequested=$false;CancelAt=$null;Forced=$false;RuleIds=[string[]]@(Get-SjcGuiValue $payload 'RuleIds' @());Profile=[string](Get-SjcGuiValue $payload 'CleaningProfile' '');CustomEnabled=[bool](Get-SjcGuiValue $payload 'CustomEnabled' $false)}
    $s.Busy=$true;if($Action -eq 'Scan'){Clear-SjcGuiScan $App}
    Set-SjcGuiStatus $App ('后台任务已启动：'+@{Scan='扫描';Clean='清理';Recycle='清空回收站'}[$Action]);Update-SjcGuiView $App
}
function Request-SjcGuiCancel {
    param($App)
    if($App.State.LocalJob){$App.State.LocalJob.Cancel.Cancel();Set-SjcGuiStatus $App '已请求取消候选操作；等待安全收尾。';return}
    $task=$App.State.Task
    if($task -and -not $task.CancelRequested){Write-SjcAtomicText $task.CancelPath 'cancel' -NoOverwrite;$task.CancelRequested=$true;$task.CancelAt=[datetime]::UtcNow;Set-SjcGuiStatus $App '已请求取消，等待实际处理结果；不代表零文件已处理。'}
}
function Complete-SjcGuiTask {
    param($App,$Result)
    $s=$App.State;$task=$s.Task;$action=$task.Action
    $s.Task=$null;$s.Busy=$false;$s.LastResult=$Result
    $status=[string](Get-SjcGuiValue $Result 'Status' 'Unknown')
    $label=@{Success='完成';Partial='部分完成';Failed='失败';Cancelled='已取消';Unknown='结果未知'}[$status]
    if(-not $label){$label=$status}
    $summary=if($status -eq 'Unknown'){'可能已经部分处理，数量和逻辑大小未知'}elseif($action -eq 'Scan'){'候选 '+[string](Get-SjcGuiValue $Result 'CandidateCount' 0)+' 个'}elseif($action -eq 'Clean'){'处理 '+[string](Get-SjcGuiValue $Result 'Deleted' '未知')+' 个，跳过 '+[string](Get-SjcGuiValue $Result 'Skipped' '未知')+' 个；逻辑大小 '+(Format-SjcGuiSize (Get-SjcGuiValue $Result 'ProcessedBytes' 0))}else{'系统回收站操作，不估计实际释放量'}
    $actionText=@{Scan='扫描';Clean='清理';Recycle='回收站'}[$action]
    $record=[pscustomobject]@{Time=(Get-Date -Format 'MM-dd HH:mm:ss');Action=$actionText;Status=$label;Summary=$summary;LogPath=[string](Get-SjcGuiValue $Result 'LogPath' '');TaskDirectory=$task.TaskDirectory;Result=$Result}
    $s.History.Insert(0,$record)
    $errorText=[string](Get-SjcGuiValue $Result 'Error' '')
    if($action -eq 'Scan'){
        $s.Scan=$Result;$s.TaskDirectory=$task.TaskDirectory;$s.PageOffset=0;$s.PageItems=@()
        $sealedProfile=[string](Get-SjcGuiValue $Result 'CleaningProfile' $task.Profile)
        $sealedCustom=Get-SjcGuiValue $Result 'CustomEnabled' $task.CustomEnabled
        $s.ScanProfile=$sealedProfile;$s.ScanCustomEnabled=[bool]$sealedCustom;$s.ScanRuleIds=@($task.RuleIds)
        $s.Stale=($status -notin @('Success','Partial'))
        if(-not $s.Stale -and ($sealedProfile -cne $s.Profile -or $sealedCustom -isnot [bool] -or $sealedCustom -ne $s.CustomEnabled)){$s.Stale=$true;$errorText+=$(if($errorText){'；'}else{''})+'扫描封存范围与当前范围不一致，需重新扫描'}
        if(-not $s.Stale -and $Result.CandidateCount -gt 0){Start-SjcGuiLocalJob $App 'Open' @{PlanPath=$Result.PlanPath}}
    }elseif($action -eq 'Clean'){$s.Stale=$true;$s.PageItems=@()}
    Set-SjcGuiStatus $App ($label+'：'+$summary+$(if($errorText){'；'+$errorText}else{''})+$(if($action -eq 'Clean'){'。需重新扫描；回收站移动不等于空间释放。'}else{''}))
    Update-SjcGuiView $App
}
function Invoke-SjcGuiTick {
    param($App)
    $s=$App.State
    if($s.LocalJob){
        $job=$s.LocalJob
        if(-not $job.Handle.IsCompleted){return}
        $closed=$false
        try{
            $values=@($job.PowerShell.EndInvoke($job.Handle))
            if($job.PowerShell.HadErrors){throw ($job.PowerShell.Streams.Error|Out-String)}
            if($job.Cancel.IsCancellationRequested){throw '候选操作已取消。'}
            if($values.Count -eq 0){throw '后台候选操作没有返回结果。'}
            $result=$values[-1]
            switch($job.Kind){
                'Open' {$s.PageOffset=0;$s.PageItems=@($result.Items)}
                'Page' {Sync-SjcGuiPageSelection $App;$s.PageOffset=$job.Arguments.Offset;$s.PageItems=@($result.Items);$App.Ui.CandidatesList.SelectedItem=$null}
                'RuleKeep' {foreach($item in @($result.Items)){if($job.Arguments.Keep){$s.Excluded[$item.Id]=[int64]$item.Length;$s.ExcludedRule[$item.Id]=[string]$item.RuleId}else{$s.Excluded.Remove($item.Id);$s.ExcludedRule.Remove($item.Id)}}}
                'Export' {Set-SjcGuiStatus $App ('完整导出 '+$result.ExportedCount+' 条候选至 '+$result.Destination)}
                'Close' {$closed=$true}
            }
            if($job.Kind -eq 'RuleKeep'){Set-SjcGuiStatus $App ($(if($job.Arguments.Keep){'已保留'}else{'已取消保留'})+'所选分类全部 '+@($result.Items).Count+' 个候选。')}
            elseif($job.Kind -notin @('Export','Close')){Set-SjcGuiStatus $App '候选操作完成。预览缓存不替代清理前校验。'}
        }catch{$s.PendingScan=$false;Set-SjcGuiStatus $App ('候选操作失败或已取消：'+$_.Exception.Message+$(if($job.Kind -eq 'Close' -and $s.PendingScope){'；范围未改变。'}else{''}));if($job.Kind -eq 'Close'){$s.PendingScope=$null}}
        finally{$job.PowerShell.Dispose();$job.Cancel.Dispose();$s.LocalJob=$null;$s.Busy=$false}
        if($s.PendingScope){$change=$s.PendingScope;$s.PendingScope=$null;if($closed){Complete-SjcGuiScope $App $change}}
        Update-SjcGuiView $App
        if($s.PendingScan){$s.PendingScan=$false;try{Start-SjcGuiTask $App 'Scan'}catch{Set-SjcGuiStatus $App ('无法开始扫描：'+$_.Exception.Message)}}
        return
    }
    if(-not $s.Task){return}
    $task=$s.Task
    if([IO.File]::Exists($task.ProgressPath)){
        try{$progress=Read-SjcSafeText $task.ProgressPath|ConvertFrom-Json;Set-SjcGuiStatus $App $progress.Text}catch{}
    }
    if($task.CancelRequested -and -not $task.Process.HasExited -and ([datetime]::UtcNow-$task.CancelAt).TotalSeconds -gt 20){$task.Process.Kill();$task.Forced=$true}
    if(-not $task.Process.HasExited){return}
    $result=$null
    try{
        if(-not $task.Forced -and [IO.File]::Exists($task.OutputPath)){$result=Read-SjcSafeText $task.OutputPath|ConvertFrom-Json}
        if($null -eq $result){$result=[pscustomobject]@{Status=$(if($task.Action -eq 'Scan'){'Failed'}else{'Unknown'});Error='后台终止或没有完整结果，可能已经部分处理，数量未知。';LogPath=''}}
    }catch{$result=[pscustomobject]@{Status='Unknown';Error=$_.Exception.Message;LogPath=''}}
    finally{$task.Process.Dispose()}
    Complete-SjcGuiTask $App $result
}
function Invoke-SjcGuiCommand {
    param($App,[string]$Command)
    $s=$App.State;$u=$App.Ui
    switch($Command){
        'FilesButton' {if(Test-SjcGuiFilesAvailable $s){[void](Open-SjcGuiFilesWindow $App)}else{Set-SjcGuiStatus $App '扫描结束且结果有效后才能查看文件明细。'}}
        'FilesToggle' {Set-SjcGuiPanel $App 'Files' (-not $s.FilesExpanded);Update-SjcGuiView $App}
        'PartialReasonButton' {if($s.Scan){Show-SjcGuiDetails $App (Get-SjcGuiPartialReasonText $s) '扫描不完整原因'}}
        'LogsToggle' {Set-SjcGuiPanel $App 'Logs' (-not $s.LogsExpanded);Update-SjcGuiView $App}
        'DismissNoticeButton' {Set-SjcGuiNotice $App ''}
        'CancelButton' {Request-SjcGuiCancel $App}
        'OpenLogButton' {$selected=$u.HistoryList.SelectedItem;if($selected -and $selected.LogPath -and [IO.File]::Exists($selected.LogPath)){[void][Diagnostics.Process]::Start('notepad.exe',('"'+$selected.LogPath+'"'))}}
        'DetailsButton' {$selected=$u.HistoryList.SelectedItem;if($selected){Show-SjcGuiDetails $App ($selected.Result|ConvertTo-Json -Depth 10)}}
        default {
            if($s.Busy -or $s.PendingScope){throw '请等待当前任务结束。'}
            switch($Command){
                'ScanButton' {if(Test-SjcGuiPreviewOpen $s){$s.PendingScan=$true;Start-SjcGuiLocalJob $App 'Close' @{};Set-SjcGuiStatus $App '正在释放旧预览，然后开始新扫描。'}else{Start-SjcGuiTask $App 'Scan'}}
                'CleanButton' {
                    if(-not (Test-SjcGuiCleanable $s)){Set-SjcGuiStatus $App '没有可清理的有效扫描，请先扫描。';return}
                    Sync-SjcGuiPageSelection $App
                    $summary=Get-SjcGuiCleanSummary $s
                    if($summary.PendingCount -le 0){Set-SjcGuiStatus $App '所有候选都已保留，没有需要清理的文件。'}
                    elseif(Confirm-SjcGuiClean $App $summary){Start-SjcGuiTask $App 'Clean'}
                    else{Set-SjcGuiStatus $App '已取消清理，没有处理任何文件。'}
                }
                'EmptyRecycleButton' {if(Confirm-SjcGui $App '永久清空当前可访问回收站，不能恢复。Windows 还会再次确认。是否继续？'){Start-SjcGuiTask $App 'Recycle'}}
                'AdvancedButton' {Show-SjcGuiAdvancedDraft $App}
                'KeepRuleButton' {$ids=Get-SjcGuiSelectedCategoryRuleIds $App;if($ids.Count -and (Test-SjcGuiCleanable $s)){Start-SjcGuiLocalJob $App 'RuleKeep' @{RuleIds=$ids;Keep=$true}}}
                'RestoreRuleButton' {$ids=Get-SjcGuiSelectedCategoryRuleIds $App;if($ids.Count -and (Test-SjcGuiCleanable $s)){Start-SjcGuiLocalJob $App 'RuleKeep' @{RuleIds=$ids;Keep=$false}}}
                'KeepButton' {
                    Sync-SjcGuiPageSelection $App;$added=0
                    foreach($id in @($s.CandidateSelection.Keys)){if(-not $s.Excluded.ContainsKey($id)){$entry=$s.CandidateSelection[$id];$s.Excluded[$id]=[int64]$entry.Length;$s.ExcludedRule[$id]=[string]$entry.RuleId;$added++}}
                    Set-SjcGuiStatus $App ('已保留 '+$added+' 个勾选文件（共勾选 '+$s.CandidateSelection.Count+' 个，可跨页）。保留的文件不会被清理。');Update-SjcGuiView $App
                }
                'RestoreButton' {
                    Sync-SjcGuiPageSelection $App;$removed=0
                    foreach($id in @($s.CandidateSelection.Keys)){if($s.Excluded.ContainsKey($id)){$s.Excluded.Remove($id);$s.ExcludedRule.Remove($id);$removed++}}
                    Set-SjcGuiStatus $App ('已取消保留 '+$removed+' 个勾选文件，它们将重新计入清理范围。');Update-SjcGuiView $App
                }
                'SelectPageButton' {foreach($row in @($u.CandidatesList.Items)){$row.IsSelected=$true};Sync-SjcGuiPageSelection $App;Update-SjcGuiView $App}
                'ClearSelectionButton' {$s.CandidateSelection.Clear();$u.CandidatesList.SelectedItem=$null;Set-SjcGuiStatus $App '已清除全部页面的勾选；保留状态不变。';Update-SjcGuiView $App}
                'CopyPathButton' {Sync-SjcGuiPageSelection $App;$paths=@($s.CandidateSelection.Values|ForEach-Object Path);if($paths.Count){[Windows.Clipboard]::SetText(($paths -join "`r`n"));Set-SjcGuiStatus $App ('已复制 '+$paths.Count+' 条勾选路径（可跨页）。')}}
                'PreviousButton' {Start-SjcGuiLocalJob $App 'Page' @{Offset=[math]::Max(0,$s.PageOffset-$s.PageSize)}}
                'NextButton' {Start-SjcGuiLocalJob $App 'Page' @{Offset=($s.PageOffset+$s.PageSize)}}
                'ExportButton' {$dialog=[Microsoft.Win32.SaveFileDialog]::new();$dialog.Filter='CSV files (*.csv)|*.csv';$dialog.FileName='清理候选_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.csv';$owner=if($App.FilesWindow -and $App.FilesWindow.IsLoaded){$App.FilesWindow}else{$u.Window};if($dialog.ShowDialog($owner)){Start-SjcGuiLocalJob $App 'Export' @{PlanPath=$s.Scan.PlanPath;Destination=$dialog.FileName;ExcludedIds=[string[]]@($s.Excluded.Keys)}}}
                'RemovePreviewButton' {$selected=$u.HistoryList.SelectedItem;if($selected -and $selected.TaskDirectory -and $selected.TaskDirectory -ne $s.TaskDirectory -and (Confirm-SjcGui $App '仅移除选中已放弃任务的预览/通道记录，不删除目标文件和日志。继续？')){[void](Remove-SjcTaskDirectory $s.Context $selected.TaskDirectory);Set-SjcGuiStatus $App '已移除任务预览记录，日志仍保留。'}}
            }
        }
    }
}
function Remove-SjcGuiApp {
    param($App)
    if(-not $App -or $App.ResourcesClosed){return}
    $App.ResourcesClosed=$true
    # 每一步独立兜底,前一步异常不跳过后续 Dispose；不终止真实维护进程,只释放句柄。
    try{if($App.Timer){$App.Timer.Stop()}}catch{}
    try{Close-SjcGuiFilesWindow $App}catch{}
    try{if($App.Maintenance){try{$App.Maintenance.Process.Dispose()}catch{};$App.Maintenance=$null}}catch{}
    try{
        if($App.State.LocalJob){$job=$App.State.LocalJob;try{$job.Cancel.Cancel()}catch{};try{$job.PowerShell.Stop()}catch{};try{$job.PowerShell.Dispose()}catch{};try{$job.Cancel.Dispose()}catch{};$App.State.LocalJob=$null}
    }catch{}
    try{
        if($App.State.Background){
            $background=$App.State.Background;$power=$null
            try{
                $power=[PowerShell]::Create();$power.Runspace=$background.Runspace
                [void]$power.AddScript('param($shared) if($shared.Preview){Close-SjcPreviewSession $shared.Preview;$shared.Preview=$null}').AddArgument($background.Shared);[void]$power.Invoke()
            }finally{if($power){try{$power.Dispose()}catch{}};try{$background.Runspace.Dispose()}catch{}}
        }
    }finally{$App.State.Busy=$false}
}
function Resolve-SjcGuiStartupPreferences {
    # 新用户（无偏好，返回 null）：中强度；读取失败：低强度 + 警告；v3 迁移提示原样显示。高级自定义启动时一律关闭。
    param($Context)
    $result=@{Profile='Medium';RecycleMode=$true;Notice=''}
    $preferences=$null
    try{$preferences=Read-SjcPreferences $Context}
    catch{$result.Profile='Low';$result.Notice=('设置读取失败，已使用低强度预设，高级自定义未启用：'+$_.Exception.Message);return $result}
    if($null -eq $preferences){return $result}
    $profile=Get-SjcGuiValue $preferences 'CleaningProfile' ''
    if($profile -is [string] -and $profile -cin @('Low','Medium','High')){$result.Profile=$profile}
    else{$result.Profile='Low';$result.Notice='设置中的清理强度无效，已使用低强度预设。'}
    $recycle=Get-SjcGuiValue $preferences 'RecycleMode' $true
    if($recycle -is [bool]){$result.RecycleMode=$recycle}
    $migration=[string](Get-SjcGuiValue $preferences 'MigrationNotice' '')
    if($migration){$result.Notice=$(if($result.Notice){$result.Notice+' '}else{''})+$migration}
    return $result
}
function Start-SjcGui {
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw '请以 PowerShell -STA 启动。'}
    $context=New-SjcContext
    $startup=Resolve-SjcGuiStartupPreferences $context
    if((Get-SjcGuiContextProfile $context) -cne $startup.Profile){
        try{Set-SjcCleaningProfile -Context $context -CleaningProfile $startup.Profile}
        catch{$startup.Notice=$(if($startup.Notice){$startup.Notice+' '}else{''})+'强度设置无法应用，使用当前引擎强度：'+$_.Exception.Message}
    }
    $state=New-SjcGuiState $context
    $state.RecycleMode=[bool]$startup.RecycleMode
    $app=New-SjcGuiApp $state
    if($startup.Notice){Set-SjcGuiNotice $app $startup.Notice}
    Update-SjcGuiView $app
    try{[void]$app.Ui.Window.ShowDialog()}finally{Remove-SjcGuiApp $app}
}
function Set-SjcGuiTestLayout {
    # 隔离渲染：设置窗口尺寸与展开状态后测量排列（不显示窗口，不做系统 UI 自动化）。
    param($App,[int]$Width,[int]$Height,[bool]$Files=$false,[bool]$Logs=$false)
    $App.Ui.Window.Width=$Width;$App.Ui.Window.Height=$Height
    Set-SjcGuiPanel $App 'Files' $Files;Set-SjcGuiPanel $App 'Logs' $Logs;Update-SjcGuiView $App
    $visual=$App.Ui.Window.Content;$visual.Measure([Windows.Size]::new($Width,$Height));$visual.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$visual.UpdateLayout()
    # 迁移后的 FilesPanel 必须挂入已呈现窗口才会布局；隔离渲染时把明细窗放到屏幕外、不激活地显示（仅测试辅助）。
    if($Files -and $App.FilesWindow){$fw=$App.FilesWindow;if(-not $fw.IsLoaded){$fw.WindowStartupLocation='Manual';$fw.Left=-32000;$fw.Top=-32000;$fw.ShowActivated=$false;$fw.Show()};$fw.UpdateLayout()}
    Resize-SjcGuiCandidateColumns $App.Ui.CandidatesList;Resize-SjcGuiCategoryColumns $App.Ui.CategoryList
    $visual.UpdateLayout();if($Files -and $App.FilesWindow){$App.FilesWindow.Content.UpdateLayout()}
}
function Save-SjcGuiRender {
    param($Window,[string]$Path)
    $visual=$Window.Content
    $visual.Measure([Windows.Size]::new($Window.Width,$Window.Height));$visual.Arrange([Windows.Rect]::new(0,0,$Window.Width,$Window.Height));$visual.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$visual.ActualWidth,[int]$visual.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $file=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write);try{$encoder.Save($file)}finally{$file.Dispose()}
}
function Get-SjcGuiTruncatedButtons {
    param($App)
    $bad=New-Object 'System.Collections.Generic.List[string]'
    foreach($key in @($App.Ui.Keys)){
        $control=$App.Ui[$key]
        if($control -isnot [Windows.Controls.Button] -or $control.Visibility -ne 'Visible' -or $control.ActualWidth -le 0){continue}
        $content=$control.Content
        if($content -isnot [Windows.UIElement]){continue}
        $content.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
        $need=$content.DesiredSize.Width+$control.Padding.Left+$control.Padding.Right+$control.BorderThickness.Left+$control.BorderThickness.Right
        if($control.ActualWidth+0.5 -lt $need){[void]$bad.Add(('{0} {1:N0}<{2:N0}' -f $key,$control.ActualWidth,$need))}
    }
    return $bad.ToArray()
}
function Wait-SjcGuiLocalJob {
    # 隔离验收用：在当前线程推进后台预览任务（不启动生产 Worker）。
    param($App,[int]$TimeoutSeconds=30)
    $limit=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while(($App.State.LocalJob -or $App.State.PendingScope) -and [datetime]::UtcNow -lt $limit){Invoke-SjcGuiTick $App;Start-Sleep -Milliseconds 20}
    if($App.State.LocalJob){throw ('后台预览任务超时：'+$App.State.Status)}
}
function Test-SjcGuiSameIds {
    param($A,$B)
    $x=[string[]]@($A|ForEach-Object{[string]$_});$y=[string[]]@($B|ForEach-Object{[string]$_})
    if($x.Count -ne $y.Count){return $false}
    [Array]::Sort($x,[StringComparer]::Ordinal);[Array]::Sort($y,[StringComparer]::Ordinal)
    for($i=0;$i -lt $x.Count;$i++){if($x[$i] -cne $y[$i]){return $false}}
    return $true
}
function Test-SjcGuiScopeFlow {
    # 范围契约在独立自有沙箱中验证，不触碰调用方给定的封存计划。
    param($Passed,[string]$ScreenshotDirectory)
    $sandbox=New-SjcTestSandbox;$context=$sandbox.Context
    $s=New-SjcGuiState $context -TestMode;$app=New-SjcGuiApp $s
    try{
        $fake={param($st) $st.Scan=[pscustomobject]@{Status='Success';CleaningProfile=$st.Profile;CustomEnabled=[bool]$st.CustomEnabled;CandidateCount=1;CandidateBytes=1;PlanPath='';Categories=@()};$st.Stale=$false;$st.Excluded['x']=[int64]1;$st.ExcludedRule['x']='SandboxOld'}
        if($s.Profile -cne 'Medium'){throw ('新上下文默认强度应为 Medium：'+$s.Profile)}
        foreach($target in @('Low','High','Medium')){
            & $fake $s;$epoch=(Get-SjcContextConfiguration $context).ProfileEpoch
            $app.Ui[('Profile'+$target)].IsChecked=$true
            if($s.Profile -cne $target -or (Get-SjcGuiContextProfile $context) -cne $target){throw ('单选未即时应用：'+$target)}
            if($null -ne $s.Scan -or -not $s.Stale -or $s.Excluded.Count){throw '切换强度未清空旧扫描与保留'}
            if((Get-SjcContextConfiguration $context).ProfileEpoch -le $epoch){throw '引擎档位 epoch 未推进'}
            if(-not (Test-SjcGuiSameIds (Get-SjcGuiPresetIds $context $target) (Get-SjcGuiEffectiveRuleIds $s))){throw '扫描范围不等于引擎预设'}
            if($app.Ui.ProfileImpact.Text -notlike ('*'+[string](Get-SjcGuiProfileInfo $target).Impact+'*')){throw '影响说明不是引擎 Impact'}
            if($target -ceq 'High' -and $app.Ui.ProfileImpactGlyph.Visibility -ne 'Visible'){throw '高强度未突出影响'}
        }
        [void]$Passed.Add('低/中/高单选 Checked 即应用（无应用按钮），真实切换引擎档位、清空旧扫描，影响文案取自引擎 Impact')
        $epoch=(Get-SjcContextConfiguration $context).ProfileEpoch
        $s.Busy=$true;Update-SjcGuiView $app
        foreach($name in @('ScanButton','CleanButton','ProfileLow','ProfileMedium','ProfileHigh','AdvancedButton','RecycleMode','EmptyRecycleButton')){if($app.Ui[$name].IsEnabled){throw ('运行中未冻结：'+$name)}}
        if(-not $app.Ui.CancelButton.IsEnabled -or $app.Ui.CancelButton.Visibility -ne 'Visible'){throw '运行中取消按钮不可用'}
        $app.Ui.ProfileHigh.IsChecked=$true
        if($s.Profile -cne 'Medium' -or $app.Ui.ProfileHigh.IsChecked -or -not $app.Ui.ProfileMedium.IsChecked -or (Get-SjcContextConfiguration $context).ProfileEpoch -ne $epoch){throw 'busy 期间切档未被拒绝或控件未回写'}
        $s.Busy=$false;Update-SjcGuiView $app
        [void]$Passed.Add('busy 冻结范围与操作控件，仅取消可用；busy 中切档被拒绝并回写真实档位')
        Complete-SjcGuiScope $app @{Profile='Deep';CustomEnabled=$false}
        if($s.Profile -cne 'Medium' -or (Get-SjcGuiContextProfile $context) -cne 'Medium' -or $s.Status -notmatch '失败' -or -not $app.Ui.ProfileMedium.IsChecked){throw '范围调整失败未恢复'}
        [void]$Passed.Add('范围调整失败时以引擎实际档位恢复界面并提示')
        if($s.CustomEnabled -or -not $app.Ui.AdvancedButton -or $app.Ui.ContainsKey('AdvancedPanel') -or $app.Ui.ContainsKey('AdvancedToggle')){throw '高级自定义默认应关闭且主窗不内嵌规则面板'}
        $presetIds=@(Get-SjcGuiPresetIds $context $s.Profile)
        & $fake $s;$epoch=(Get-SjcContextConfiguration $context).ProfileEpoch
        $dw=New-SjcGuiAdvancedDraftWindow $app;$d=$dw.Tag
        if(@($d.Rows).Count -ne $s.Rules.Count -or -not (Test-SjcGuiSameIds $presetIds @($d.Ids))){$dw.Close();throw '草稿窗未从当前预设开始'}
        $view=[Windows.Data.CollectionViewSource]::GetDefaultView($d.List.ItemsSource);if(-not $view -or $view.GroupDescriptions.Count -ne 1){$dw.Close();throw '草稿窗未按 Group 分组'}
        $victim=[string]@($d.Ids)[0];[void]$d.Ids.Remove($victim)
        if(-not $s.Selected.Contains($victim) -or $s.CustomEnabled -or $null -eq $s.Scan){$dw.Close();throw '草稿勾选泄漏到现有 Selected'}
        $dw.Close()
        if($s.CustomEnabled -or $null -eq $s.Scan -or $s.Stale -or (Get-SjcContextConfiguration $context).ProfileEpoch -ne $epoch){throw '取消/关闭草稿改变了范围或旧扫描'}
        $ids=[string[]]@($presetIds|Where-Object{$_ -cne $victim})
        if($ids.Count -eq 0){$ids=[string[]]@($s.Rules|Select-Object -First 1|ForEach-Object{[string]$_.Id})}
        if(-not (Confirm-SjcGuiAdvancedDraft $app $ids)){throw '草稿确定未应用'}
        if(-not $s.CustomEnabled -or $null -ne $s.Scan -or -not $s.Stale -or -not (Test-SjcGuiSameIds $ids @($s.Selected)) -or $app.Ui.ProfileMedium.IsChecked){throw '草稿确定未一次应用或未清旧扫描'}
        $payload=New-SjcGuiTaskPayload $s 'Scan' 'T' 'P' 'C'
        if($payload.CustomEnabled -isnot [bool] -or -not $payload.CustomEnabled -or $payload.CleaningProfile -cne $s.Profile -or -not (Test-SjcGuiSameIds $payload.RuleIds @($s.CustomSelected))){throw '自定义扫描载荷不符'}
        & $fake $s;$epoch=(Get-SjcContextConfiguration $context).ProfileEpoch
        if(Confirm-SjcGuiAdvancedDraft $app $ids){throw '集合与模式未变化时不应重新应用'}
        if($null -eq $s.Scan -or $s.Stale -or (Get-SjcContextConfiguration $context).ProfileEpoch -ne $epoch){throw '集合未变化确定却使扫描失效'}
        if($ScreenshotDirectory){Set-SjcGuiTestLayout $app 900 680;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory 'Advanced-900x680.png')}
        $app.Ui[('Profile'+$s.Profile)].IsChecked=$true
        if($s.CustomEnabled -or -not (Test-SjcGuiSameIds $presetIds @($s.Selected))){throw '选中档位未恢复预设'}
        [void]$Passed.Add('高级自定义改为模态草稿窗：独立勾选集合，取消不改范围；确定一次应用并清旧扫描，未变化不失效；选中低/中/高恢复预设')
        for($i=0;$i -lt 3;$i++){$p=Join-Path $sandbox.Root ('files\scope-{0}.tmp' -f $i);[IO.File]::WriteAllText($p,'scope');[IO.File]::SetLastWriteTimeUtc($p,[datetime]::UtcNow.AddDays(-5))}
        $task=New-SjcTaskDirectory $context
        $scan=Invoke-SjcScan -Context $context -RuleIds ([string[]]@(Get-SjcGuiPresetIds $context $s.Profile)) -TaskDirectory $task -CustomEnabled $false
        if($scan.Status -ne 'Success'){throw ('沙箱预设扫描失败：'+$scan.Error)}
        $s.Scan=$scan;$s.ScanProfile=$scan.CleaningProfile;$s.ScanCustomEnabled=$scan.CustomEnabled;$s.TaskDirectory=$task;$s.Stale=$false
        Start-SjcGuiLocalJob $app 'Open' @{PlanPath=$scan.PlanPath};Wait-SjcGuiLocalJob $app
        if(-not (Test-SjcGuiPreviewOpen $s) -or $s.PageItems.Count -ne 3){throw ('预览会话未打开：'+$s.Status)}
        $app.Ui.ProfileHigh.IsChecked=$true
        if(-not $s.PendingScope -or -not $s.Busy -or $s.Profile -cne 'Medium'){throw '有预览时切档应先异步释放预览'}
        Wait-SjcGuiLocalJob $app
        if((Test-SjcGuiPreviewOpen $s) -or $s.Profile -cne 'High' -or (Get-SjcGuiContextProfile $context) -cne 'High' -or $null -ne $s.Scan -or $s.Busy){throw ('异步释放后未切档：'+$s.Status)}
        if(-not [IO.File]::Exists((Join-Path $task 'profile.invalidated'))){throw '旧计划未被引擎标记失效'}
        [void]$Passed.Add('后台 runspace 复用：切档先异步 Close 预览再 Set-SjcCleaningProfile，旧计划失效')
    }finally{Remove-SjcGuiApp $app;$app.Ui.Window.Close()}
}
function Test-SjcGui {
    param([string]$PlanPath,[string]$ScreenshotDirectory)
    $passed=New-Object 'System.Collections.Generic.List[string]';$failed=New-Object 'System.Collections.Generic.List[string]';$skipped=New-Object 'System.Collections.Generic.List[string]';$app=$null;$session=$null;$confirm=$null
    try{
        Initialize-SjcDesktop
        if($ScreenshotDirectory){[void][IO.Directory]::CreateDirectory($ScreenshotDirectory)}
        $xaml=Get-SjcWorkbenchXaml
        if($xaml.Contains('{G:') -or $xaml -match 'Canvas|DropShadowEffect|LinearGradientBrush'){throw '图标映射未展开或仍有自绘装饰'}
        foreach($legacy in @('NavHome','NavFiles','NavRules','NavLogs','HomePage','FilesPage','RulesPage','LogsPage','ApplyRulesButton','CancelRulesButton','ProfileRecommended','ProfileDeep','应用范围')){if($xaml.Contains($legacy)){throw ('仍残留旧四页/应用按钮控件：'+$legacy)}}
        [void]$passed.Add('单窗口：无导航与四页工作区，无“应用范围”按钮；操作图标经集中 MDL2 映射展开，无自绘装饰')
        $context=if($PlanPath){Get-SjcPlanContext ([IO.Path]::GetDirectoryName($PlanPath))}else{New-SjcTestSandbox|ForEach-Object Context}
        $s=New-SjcGuiState $context -TestMode;$app=New-SjcGuiApp $s
        if($app.Ui.Window.Width -ne 900 -or $app.Ui.Window.Height -ne 680 -or $app.Ui.Window.MinWidth -gt 760 -or $app.Ui.Window.MinHeight -gt 600){throw '窗口尺寸不是约 900x680'}
        if(Get-SjcGuiIconPath){if(-not $app.Ui.Window.Icon -or -not $app.Ui.BrandIcon.Source){throw '应用图标未加载到窗口'};[void]$passed.Add('窗口与白底头部使用原 assets\app.ico')}else{[void]$skipped.Add('未从源码入口运行，窗口图标路径未测')}
        if($s.CustomEnabled -or $s.FilesExpanded -or $app.FilesWindow -or $null -ne $app.Ui.FilesPanel.Parent -or $app.Ui.FilesButton.IsEnabled -or $app.Ui.LogsPanel.Visibility -ne 'Collapsed'){throw '高级/文件明细/任务记录默认应折叠'}
        if(-not (Test-SjcGuiSameIds (Get-SjcGuiPresetIds $context $s.Profile) (Get-SjcGuiEffectiveRuleIds $s)) -or -not $app.Ui[('Profile'+$s.Profile)].IsChecked){throw '默认范围不是引擎预设'}
        $payload=New-SjcGuiTaskPayload $s 'Scan' 'T' 'P' 'C'
        if($payload.CustomEnabled -isnot [bool] -or $payload.CustomEnabled -or $payload.CleaningProfile -cne $s.Profile -or -not (Test-SjcGuiSameIds $payload.RuleIds (Get-SjcGuiPresetIds $context $s.Profile))){throw '预设扫描载荷不符合 CleaningProfile/CustomEnabled/精确预设契约'}
        $blocked=$false;try{Start-SjcGuiTask $app 'Scan'}catch{$blocked=($_.Exception.Message -match '不允许')}
        if(-not $blocked){throw '隔离模式不应启动生产 Worker'}
        [void]$passed.Add('默认折叠高级/明细/记录；预设扫描载荷显式 CleaningProfile 与布尔 CustomEnabled=false，RuleIds 精确等于引擎预设；TestMode 拒绝生产 Worker')
        Test-SjcGuiScopeFlow $passed $ScreenshotDirectory
        $s.History.Add([pscustomobject]@{Time='01-01 12:00:00';Action='扫描';Status='完成';Summary='人工记录A';LogPath='';TaskDirectory='';Result=$null})
        $s.History.Add([pscustomobject]@{Time='01-01 12:01:00';Action='清理';Status='已取消';Summary='人工记录B';LogPath='';TaskDirectory='';Result=$null})
        Invoke-SjcGuiCommand $app 'LogsToggle';$app.Ui.HistoryList.SelectedIndex=1;Update-SjcGuiView $app
        if($app.Ui.LogsPanel.Visibility -ne 'Visible' -or $app.Ui.HistoryList.SelectedItem.Summary -ne '人工记录B'){throw '任务记录小入口展开或当前选择丢失'}
        Invoke-SjcGuiCommand $app 'LogsToggle'
        if($app.Ui.LogsPanel.Visibility -ne 'Collapsed'){throw '任务记录未收起'}
        [void]$passed.Add('任务记录为状态栏小入口，按需展开且保留当前选择')
        if($PlanPath){
            $task=[IO.Path]::GetDirectoryName((Get-SjcFullPath $PlanPath))
            $meta=Unprotect-SjcText (Read-SjcSafeText (Join-Path $task 'scan.meta.json'))|ConvertFrom-Json -ErrorAction Stop
            if([string]$meta.CleaningProfile -cne $s.Profile){throw '给定计划档位与上下文不一致'}
            $session=Open-SjcPreviewSession $PlanPath;$items=@(Get-SjcPreviewPage $session -Limit 200)
            $cats=@(@($s.Rules)|Where-Object{@($meta.RuleIds) -contains $_.Id}|ForEach-Object{$rid=$_.Id;$list=@(if($session.ByRule.ContainsKey($rid)){$session.ByRule[$rid].ToArray()});[pscustomobject]@{RuleId=$rid;Name=$_.Name;Group=$_.Group;Risk=$_.Risk;Root=$_.Root;Count=[int64]$list.Count;Bytes=$(if($list.Count){[int64](($list|Measure-Object Length -Sum).Sum)}else{[int64]0});Status='Success';Note=$_.Note}})
            # 计划由调用方以真实封存扫描生成；界面范围对齐封存的 CustomEnabled 与 RuleIds（不改引擎档位）。
            $s.CustomEnabled=[bool]$meta.CustomEnabled;$s.CustomSelected.Clear();foreach($id in @($meta.RuleIds)){[void]$s.CustomSelected.Add([string]$id)};$s.CustomInitialized=$true
            $s.Selected.Clear();foreach($id in @(Get-SjcGuiEffectiveRuleIds $s)){[void]$s.Selected.Add($id)};Update-SjcGuiRuleRows $app
            $s.Scan=[pscustomobject]@{Status='Success';CleaningProfile=[string]$meta.CleaningProfile;CustomEnabled=[bool]$meta.CustomEnabled;CandidateCount=$session.Count;CandidateBytes=$session.Bytes;PlanPath=$PlanPath;Categories=$cats}
            $s.ScanProfile=[string]$meta.CleaningProfile;$s.ScanCustomEnabled=[bool]$meta.CustomEnabled;$s.TaskDirectory=$task;$s.Stale=$false;$s.PageItems=$items;Update-SjcGuiView $app
            $sum=0;foreach($row in @($app.Ui.CategoryList.Items)){$sum+=[int64]$row.Count}
            if(@($app.Ui.CategoryList.Items).Count -ne $cats.Count -or $sum -ne $session.Count){throw ('分类主表与封存候选总数不符：'+$sum+'/'+$session.Count)}
            if($app.FilesWindow -or -not $app.Ui.FilesButton.IsEnabled){throw '文件明细不应默认打开，或有效扫描后按钮不可用'}
            Invoke-SjcGuiCommand $app 'FilesButton'
            if(-not $app.FilesWindow -or -not [object]::ReferenceEquals($app.FilesWindow.Content,$app.Ui.FilesPanel) -or ($session.Count -gt 0 -and $app.Ui.CandidatesList.Items.Count -ne [math]::Min(200,$session.Count))){throw '展开文件明细未显示真实分页'}
            [void]$passed.Add('T17 真实封存计划：分类主表合计等于封存候选，文件明细按需展开并分页（每页 200）')
            if($items.Count){
                $first=$app.Ui.CandidatesList.Items[0]
                $check=[Windows.Controls.CheckBox]::new();$check.DataContext=$first;$check.IsChecked=$true
                Set-SjcGuiCandidateSelection $app $check
                if($s.Excluded.Count -ne 0){throw '勾选与保留混淆'}
                Invoke-SjcGuiCommand $app 'KeepButton'
                if($app.Ui.MetricKept.Text -ne '1' -or -not $app.Ui.CandidatesList.Items[0].IsSelected){throw '保留项统计或勾选保持错误'}
                Invoke-SjcGuiCommand $app 'RestoreButton'
                if($s.Excluded.Count -ne 0){throw '取消保留没有移除保留项'}
                $app.Ui.CandidatesList.SelectedItem=$app.Ui.CandidatesList.Items[0]
                if(-not $app.Ui.SelectedPathText.Text.Contains($first.Path)){throw '完整路径详情缺失'}
                [void]$passed.Add('勾选与保留独立、取消保留及完整路径详情')
                if($session.Count -gt 200){
                    Sync-SjcGuiPageSelection $app;$s.PageOffset=200;$s.PageItems=@(Get-SjcPreviewPage $session -Offset 200 -Limit 200);$app.Ui.CandidatesList.SelectedItem=$null;Update-SjcGuiView $app
                    $app.Ui.CandidatesList.Items[0].IsSelected=$true
                    Invoke-SjcGuiCommand $app 'KeepButton'
                    if($s.Excluded.Count -ne 2 -or $s.CandidateSelection.Count -ne 2 -or $app.Ui.SelectionSummaryText.Text -notmatch '其他页 1'){throw ('跨页勾选与保留不一致：'+$app.Ui.SelectionSummaryText.Text)}
                    [void]$passed.Add('跨页分页、勾选保持与保留一致')
                }else{[void]$skipped.Add('计划不足 200 条，跨页未测')}
                $summary=Get-SjcGuiCleanSummary $s
                $rowSum=if(@($summary.Rows).Count){(@($summary.Rows)|Measure-Object Count -Sum).Sum}else{0}
                if($summary.PendingCount -ne ($session.Count-$s.Excluded.Count) -or $rowSum -ne $summary.PendingCount){throw '清理确认范围与全部未保留数量不符'}
                if($summary.Profile -cne [string]$meta.CleaningProfile -or $summary.CustomEnabled -ne [bool]$meta.CustomEnabled -or $summary.Impact -cne [string](Get-SjcGuiProfileInfo $summary.Profile).Impact){throw '确认摘要未使用扫描真实档位与引擎 Impact'}
                $clean=New-SjcGuiTaskPayload $s 'Clean' $task 'P' 'C'
                if($clean.CleaningProfile -cne [string]$meta.CleaningProfile -or $clean.CustomEnabled -isnot [bool] -or $clean.CustomEnabled -ne [bool]$meta.CustomEnabled -or @($clean.ExcludedIds).Count -ne $s.Excluded.Count){throw '清理载荷未取扫描封存档位/自定义模式'}
                $s.CustomEnabled=-not $s.CustomEnabled;$mismatch=$false;try{[void](New-SjcGuiTaskPayload $s 'Clean' $task 'P' 'C')}catch{$mismatch=$true};$s.CustomEnabled=-not $s.CustomEnabled
                if(-not $mismatch){throw '范围与扫描封存不一致时仍生成清理载荷'}
                $confirm=New-SjcGuiCleanConfirmWindow $app $summary
                if($confirm.FindName('Headline').Text -notmatch ('{0:N0}' -f $summary.PendingCount) -or $confirm.FindName('CheckedText').Text -notmatch '不限定' -or $confirm.FindName('ProfileText').Text -notlike ('*'+$summary.ProfileLabel+'*') -or $confirm.FindName('ImpactText').Text -cne $summary.Impact){throw '清理确认未显示全部未保留范围、扫描档位与影响'}
                Invoke-SjcGuiCommand $app 'CleanButton'
                if($s.Busy -or $s.Status -notmatch '已取消清理'){throw 'TestMode 下清理确认应拒绝且不启动任务'}
                [void]$passed.Add('清理确认含全部未保留候选、扫描真实档位/自定义与引擎 Impact；Clean 载荷取扫描封存；范围变化拒绝清理')
                if($ScreenshotDirectory){$confirm.Width=880;$confirm.Height=560;Save-SjcGuiRender $confirm (Join-Path $ScreenshotDirectory 'Confirm.png')}
                $s.RecycleMode=$false;$permanent=New-SjcGuiCleanConfirmWindow $app (Get-SjcGuiCleanSummary $s);$s.RecycleMode=$true
                if($permanent.FindName('AcceptConfirm').Content -ne '永久删除' -or $permanent.FindName('ModeText').Text -notmatch '永久'){throw '永久删除确认未区分'};$permanent.Close()
                [void]$passed.Add('永久删除确认单独区分（实际运行时另有二次确认）')
            }
        }else{[void]$skipped.Add('未给PlanPath,真实分页未测')}
        foreach($size in @(@(900,680),@(760,600))){
            foreach($files in @($false,$true)){
                Set-SjcGuiTestLayout $app $size[0] $size[1] $files $false
                $bad=@(Get-SjcGuiTruncatedButtons $app)
                if($bad.Count){throw ('按钮文字被截断 {0}x{1} 明细={2}: {3}' -f $size[0],$size[1],$files,($bad -join '; '))}
                if($app.Ui.ScanButton.ActualHeight -lt 28 -or $app.Ui.ScanButton.ActualWidth -lt 50 -or $app.Ui.CleanButton.ActualWidth -lt 50){throw '扫描/清理按钮未获得完整布局空间'}
                if($app.Ui.CategoryList.ActualHeight -lt $(if($files){45}else{60})){throw ('分类主表高度不足：'+$app.Ui.CategoryList.ActualHeight)}
                if($files -and $app.Ui.CandidatesList.ActualHeight -lt 60){throw ('文件明细列表高度不足：'+$app.Ui.CandidatesList.ActualHeight)}
            }
            [void]$passed.Add(('核心按钮常见且无截断，分类主表/文件明细可用 {0}x{1}' -f $size[0],$size[1]))
        }
        if($app.Ui.CandidatesList.Items.Count){
            Set-SjcGuiTestLayout $app 900 680 $true $false
            $container=$app.Ui.CandidatesList.ItemContainerGenerator.ContainerFromIndex(0)
            if(-not $container -or $container.ActualHeight -lt 26 -or $container.ActualHeight -gt 34){throw ('候选行高不在 26-34 DIP：'+$(if($container){$container.ActualHeight}else{'无容器'}))}
            $generated=0;for($i=0;$i -lt $app.Ui.CandidatesList.Items.Count;$i++){if($app.Ui.CandidatesList.ItemContainerGenerator.ContainerFromIndex($i)){$generated++}}
            if($generated -ge $app.Ui.CandidatesList.Items.Count -and $app.Ui.CandidatesList.Items.Count -gt 60){throw '候选表格未虚拟化'}
            [void]$passed.Add(('候选表格虚拟化，行高 {0} DIP，生成容器 {1}/{2}' -f $container.ActualHeight,$generated,$app.Ui.CandidatesList.Items.Count))
            foreach($size in @(@(900,680),@(760,600))){
                Set-SjcGuiTestLayout $app $size[0] $size[1] $true $false
                foreach($list in @($app.Ui.CandidatesList,$app.Ui.CategoryList)){
                    $total=0;foreach($column in $list.View.Columns){$total+=$column.Width}
                    if($total -gt $list.ActualWidth-18){throw ('{0} 列在 {1}x{2} 溢出：{3:N0}/{4:N0}' -f $list.Name,$size[0],$size[1],$total,$list.ActualWidth)}
                }
            }
            [void]$passed.Add('分类主表与候选表格列在 900x680 与 760x600 内完整显示')
        }
        if($ScreenshotDirectory){
            Set-SjcGuiTestLayout $app 900 680 $false $false;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory 'Main-900x680.png')
            Set-SjcGuiTestLayout $app 900 680 $true $false;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory 'Files-900x680.png');Save-SjcGuiRender $app.FilesWindow (Join-Path $ScreenshotDirectory 'FilesWindow.png')
            Set-SjcGuiTestLayout $app 900 680 $false $true;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory 'Logs-900x680.png')
            Set-SjcGuiTestLayout $app 760 600 $true $false;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory 'Files-760x600.png')
            Set-SjcGuiTestLayout $app 900 680 $false $false
        }
        [void]$skipped.Add('真实显示器DPI/回收站系统确认/真实窗口交互需要主代理桌面验收')
    }catch{[void]$failed.Add($_.Exception.Message+' @ '+$_.ScriptStackTrace)}
    finally{if($confirm){$confirm.Close()};if($session){Close-SjcPreviewSession $session};if($app){Remove-SjcGuiApp $app;$app.Ui.Window.Close()}}
    return [pscustomobject]@{Name='Test-SjcGui';Version=(Get-SjcVersion);Status=$(if($failed.Count){'Failed'}else{'Success'});Passed=[string[]]$passed.ToArray();Failed=[string[]]$failed.ToArray();Skipped=[string[]]$skipped.ToArray()}
}
