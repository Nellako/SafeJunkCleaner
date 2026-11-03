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
# 操作图标统一使用 Windows 系统字体 Segoe MDL2 Assets（不随应用分发）。语义名到码位的唯一映射。
function Get-SjcGuiGlyphMap {
    return @{
        Home='E80F';Files='E8A5';Rules='E71C';Logs='E81C';Scan='E721';ViewFiles='E8FD';Cancel='E711'
        Previous='E76B';Next='E76C';Keep='E72E';Unkeep='E785';Copy='E8C8';Export='EDE1';Clean='E74D'
        EmptyRecycle='E74D';Apply='E73E';Discard='E7A7';Recommended='E734';SelectAll='E8B3';ClearSelection='E8E6'
        CheckPage='E73A';OpenLog='E8E5';Details='E946';RemoveRecord='E74D';Size='EDA2';Kept='E72E'
        Shield='EA18';Ok='E73E';Warning='E7BA';Search='E721';Profile='E713';ChevronRight='E76C'
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
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="星梦雨垃圾清理器 v__PRODUCT_VERSION__" Width="1200" Height="820" MinWidth="960" MinHeight="700" WindowStartupLocation="CenterScreen" Background="#F3F6FB" FontFamily="Microsoft YaHei UI" FontSize="14" Foreground="#16213A" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
 <Window.Resources>
  <SolidColorBrush x:Key="Blue" Color="#2F6BFF"/>
  <SolidColorBrush x:Key="BlueSoft" Color="#EAF1FF"/>
  <SolidColorBrush x:Key="BlueInk" Color="#1C3F9E"/>
  <SolidColorBrush x:Key="Line" Color="#E6EBF3"/>
  <SolidColorBrush x:Key="Ink2" Color="#3D4A63"/>
  <SolidColorBrush x:Key="Ink3" Color="#6B7890"/>
  <Style x:Key="Muted" TargetType="TextBlock"><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  <Style x:Key="Title" TargetType="TextBlock"><Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  <Style x:Key="Glyph" TargetType="TextBlock"><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="14"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextWrapping" Value="NoWrap"/></Style>
  <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextWrapping" Value="NoWrap"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="10"/><Setter Property="Padding" Value="16"/><Setter Property="Margin" Value="0,0,0,14"/><Setter Property="BorderBrush" Value="#E6EBF3"/><Setter Property="BorderThickness" Value="1"/></Style>
  <Style TargetType="Button"><Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="BorderBrush" Value="#D5DEEB"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="12,6"/><Setter Property="MinHeight" Value="32"/><Setter Property="Margin" Value="0,0,8,8"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Cursor" Value="Hand"/><Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="False"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="#2F6BFF"/><Setter TargetName="Chrome" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F4F7FC"/><Setter Property="Foreground" Value="#16213A"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#EBEFF6"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger></Style.Triggers></Style>
  <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#2F6BFF"/><Setter Property="BorderBrush" Value="#2F6BFF"/><Setter Property="Foreground" Value="White"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#245BE0"/><Setter Property="Foreground" Value="White"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#1C4CC2"/></Trigger></Style.Triggers></Style>
  <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#C2342B"/><Setter Property="BorderBrush" Value="#C2342B"/><Setter Property="Foreground" Value="White"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#A82A22"/><Setter Property="Foreground" Value="White"/></Trigger></Style.Triggers></Style>
  <Style x:Key="LinkButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="Foreground" Value="#2F6BFF"/><Setter Property="FontWeight" Value="Normal"/><Setter Property="FontSize" Value="12"/><Setter Property="Padding" Value="6,2"/><Setter Property="MinHeight" Value="24"/><Setter Property="Margin" Value="4,0,0,0"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#EAF1FF"/><Setter Property="Foreground" Value="#1C3F9E"/></Trigger></Style.Triggers></Style>
  <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="14,10"/><Setter Property="Margin" Value="0,2"/></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/></Style>
  <Style TargetType="RadioButton"><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Margin" Value="0,0,18,0"/><Setter Property="Cursor" Value="Hand"/></Style>
  <Style TargetType="GridViewColumnHeader"><Setter Property="Background" Value="#F7F9FD"/><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="Padding" Value="8,6"/><Setter Property="BorderBrush" Value="#E6EBF3"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
 </Window.Resources>
 <Grid>
  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
   <DockPanel Margin="12,18,12,16">
    <StackPanel DockPanel.Dock="Top" Margin="6,0,0,20" Orientation="Horizontal"><Border Width="40" Height="40" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Margin="0,0,10,0"><Image x:Name="BrandIcon" Width="36" Height="36" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" AutomationProperties.Name="应用图标"/></Border><StackPanel VerticalAlignment="Center"><TextBlock Text="星梦雨垃圾清理器" FontWeight="SemiBold" FontSize="14" TextWrapping="NoWrap"/><TextBlock Text="安全清理工作台" Style="{StaticResource Muted}" Margin="0,2,0,0"/></StackPanel></StackPanel>
    <Border DockPanel.Dock="Bottom" Background="{StaticResource BlueSoft}" CornerRadius="8" Padding="10"><DockPanel><TextBlock DockPanel.Dock="Left" Text="{G:Shield}" Style="{StaticResource Glyph}" Foreground="#6B7890" FontSize="12" VerticalAlignment="Top" Margin="0,2,6,0"/><TextBlock Text="仅处理已核实的缓存与临时文件。不提权，不结束应用。" Style="{StaticResource Muted}"/></DockPanel></Border>
    <StackPanel><TextBlock Text="工作区" Style="{StaticResource Muted}" Margin="10,0,0,6"/>
     <Button x:Name="NavHome" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Home}" Style="{StaticResource Glyph}" Margin="0,0,10,0"/><TextBlock Text="工作台"/></StackPanel></Button>
     <Button x:Name="NavFiles" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Files}" Style="{StaticResource Glyph}" Margin="0,0,10,0"/><TextBlock Text="候选文件"/></StackPanel></Button>
     <Button x:Name="NavRules" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Rules}" Style="{StaticResource Glyph}" Margin="0,0,10,0"/><TextBlock Text="清理规则"/></StackPanel></Button>
     <Button x:Name="NavLogs" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Logs}" Style="{StaticResource Glyph}" Margin="0,0,10,0"/><TextBlock Text="任务记录"/></StackPanel></Button>
    </StackPanel>
   </DockPanel>
  </Border>
  <Grid Grid.Column="1">
   <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Border Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="20,0"><DockPanel VerticalAlignment="Center"><Border DockPanel.Dock="Right" Background="{StaticResource BlueSoft}" CornerRadius="6" Padding="8,3"><TextBlock Text="v__PRODUCT_VERSION__" Foreground="{StaticResource BlueInk}" FontSize="12" FontWeight="Medium"/></Border><TextBlock x:Name="Breadcrumb" Text="星梦雨垃圾清理器  /  工作台" Foreground="#6B7890" FontSize="13"/></DockPanel></Border>
   <Grid Grid.Row="1" Margin="20,16,20,0">
    <ScrollViewer x:Name="HomePage" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
     <StackPanel MaxWidth="1100">
      <TextBlock Text="清理工作台" Style="{StaticResource Title}"/><TextBlock Text="扫描只生成预览，不删除文件；清理前会再次确认范围。" Style="{StaticResource Muted}" Margin="0,4,0,14"/>
      <Border Background="{StaticResource BlueSoft}" BorderBrush="#D6E3FF" BorderThickness="1" CornerRadius="10" Padding="20,16" Margin="0,0,0,14">
       <StackPanel><TextBlock Text="检查可以安全整理的空间" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource BlueInk}"/><TextBlock Text="默认移入回收站。扫描结果在“候选文件”中逐项查看，可保留任意文件。" Foreground="#3D4A63" Margin="0,4,0,12" FontSize="13" TextWrapping="Wrap"/>
        <WrapPanel><Button x:Name="ScanButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Scan}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="开始扫描"/></StackPanel></Button><Button x:Name="ViewFilesButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:ViewFiles}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="查看候选"/></StackPanel></Button><Button x:Name="CancelButton" Visibility="Collapsed" Foreground="#C2342B" BorderBrush="#F1C7C3"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Cancel}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="取消任务"/></StackPanel></Button></WrapPanel>
        <TextBlock x:Name="ScopeText" Style="{StaticResource Muted}" Margin="0,4,0,0"/></StackPanel>
      </Border>
      <UniformGrid Columns="3" Margin="0,0,-14,0">
       <Border Style="{StaticResource Card}" Margin="0,0,14,14"><DockPanel><TextBlock DockPanel.Dock="Left" Text="{G:Size}" Style="{StaticResource Glyph}" Foreground="{StaticResource Blue}" FontSize="18" VerticalAlignment="Top" Margin="0,2,12,0"/><StackPanel><TextBlock Text="候选逻辑大小" Style="{StaticResource Muted}"/><TextBlock x:Name="MetricBytes" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/><TextBlock Text="扫描预估，不等于实际释放" Style="{StaticResource Muted}"/></StackPanel></DockPanel></Border>
       <Border Style="{StaticResource Card}" Margin="0,0,14,14"><DockPanel><TextBlock DockPanel.Dock="Left" Text="{G:Files}" Style="{StaticResource Glyph}" Foreground="#14935A" FontSize="18" VerticalAlignment="Top" Margin="0,2,12,0"/><StackPanel><TextBlock Text="候选文件" Style="{StaticResource Muted}"/><TextBlock x:Name="MetricCount" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/><TextBlock x:Name="PendingText" Text="尚未扫描" Style="{StaticResource Muted}"/></StackPanel></DockPanel></Border>
       <Border Style="{StaticResource Card}" Margin="0,0,14,14"><DockPanel><TextBlock DockPanel.Dock="Left" Text="{G:Kept}" Style="{StaticResource Glyph}" Foreground="#B4630A" FontSize="18" VerticalAlignment="Top" Margin="0,2,12,0"/><StackPanel><TextBlock Text="保留项（不处理）" Style="{StaticResource Muted}"/><TextBlock x:Name="MetricKept" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/><TextBlock Text="保留只会减少处理范围" Style="{StaticResource Muted}"/></StackPanel></DockPanel></Border>
      </UniformGrid>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="280"/></Grid.ColumnDefinitions>
       <Border Style="{StaticResource Card}"><StackPanel><DockPanel Margin="0,0,0,8"><Button x:Name="AdjustRulesButton" DockPanel.Dock="Right" Style="{StaticResource LinkButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="调整范围"/><TextBlock Text="{G:ChevronRight}" Style="{StaticResource Glyph}" FontSize="10" Margin="4,0,0,0"/></StackPanel></Button><TextBlock Text="分类清理" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/></DockPanel><ItemsControl x:Name="CategoryList"><ItemsControl.ItemTemplate><DataTemplate><Border Padding="0,8" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="120"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="{Binding Name}" FontWeight="Medium" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" ToolTip="{Binding Name}"/><TextBlock Text="{Binding StatusText}" Style="{StaticResource Muted}" Margin="0,2,0,0"/></StackPanel><StackPanel Grid.Column="1" HorizontalAlignment="Right"><TextBlock Text="{Binding SizeText}" HorizontalAlignment="Right" FontWeight="Medium"/><TextBlock Text="{Binding CountText}" Style="{StaticResource Muted}" HorizontalAlignment="Right" Margin="0,2,0,0"/></StackPanel></Grid></Border></DataTemplate></ItemsControl.ItemTemplate></ItemsControl></StackPanel></Border>
       <Border Grid.Column="2" Style="{StaticResource Card}"><StackPanel><TextBlock Text="安全策略" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,10"/><DockPanel Margin="0,0,0,8"><TextBlock DockPanel.Dock="Left" Text="{G:Ok}" Style="{StaticResource Glyph}" Foreground="#14935A" Margin="0,0,8,0"/><TextBlock Text="只处理已批准的精确目录" Foreground="#3D4A63" FontSize="13" TextWrapping="Wrap"/></DockPanel><DockPanel Margin="0,0,0,8"><TextBlock DockPanel.Dock="Left" Text="{G:Ok}" Style="{StaticResource Glyph}" Foreground="#14935A" Margin="0,0,8,0"/><TextBlock Text="清理前复核路径与文件身份" Foreground="#3D4A63" FontSize="13" TextWrapping="Wrap"/></DockPanel><DockPanel><TextBlock DockPanel.Dock="Left" Text="{G:Ok}" Style="{StaticResource Glyph}" Foreground="#14935A" Margin="0,0,8,0"/><TextBlock Text="文件变化或只读时跳过" Foreground="#3D4A63" FontSize="13" TextWrapping="Wrap"/></DockPanel><Border Height="1" Background="{StaticResource Line}" Margin="0,12,0,10"/><CheckBox x:Name="RecycleMode" Content="移入回收站（推荐）" IsChecked="True" FontWeight="Medium"/><TextBlock Text="移入回收站通常不会立即释放空间。" Style="{StaticResource Muted}" Margin="0,4,0,10"/><Button x:Name="EmptyRecycleButton" Foreground="#C2342B" BorderBrush="#F1C7C3" HorizontalAlignment="Left"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:EmptyRecycle}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="清空回收站…"/></StackPanel></Button></StackPanel></Border>
      </Grid>
      <Border Style="{StaticResource Card}"><StackPanel><TextBlock Text="最近任务" FontSize="15" FontWeight="SemiBold"/><TextBlock x:Name="LastTaskText" Text="尚无任务。扫描完成后，可查看候选再决定处理。" Style="{StaticResource Muted}" Margin="0,8,0,0"/></StackPanel></Border>
     </StackPanel>
    </ScrollViewer>
    <Grid x:Name="FilesPage" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <StackPanel><TextBlock Text="候选文件" Style="{StaticResource Title}"/><TextBlock Text="完整候选分页查看（每页 200 条）。勾选可跨页保持；“保留”的文件不会被清理。" Style="{StaticResource Muted}" Margin="0,4,0,10"/>
      <WrapPanel><Button x:Name="KeepButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Keep}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock x:Name="KeepButtonText" Text="保留已勾选"/></StackPanel></Button><Button x:Name="RestoreButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Unkeep}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock x:Name="RestoreButtonText" Text="取消保留已勾选"/></StackPanel></Button><Button x:Name="SelectPageButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:CheckPage}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="勾选本页"/></StackPanel></Button><Button x:Name="ClearSelectionButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:ClearSelection}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="清除全部勾选"/></StackPanel></Button><Button x:Name="CopyPathButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Copy}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="复制路径"/></StackPanel></Button><Button x:Name="ExportButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Export}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="完整导出 CSV"/></StackPanel></Button><Button x:Name="CleanButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Clean}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock x:Name="CleanButtonText" Text="清理未保留候选…"/></StackPanel></Button></WrapPanel></StackPanel>
     <Border Grid.Row="1" Background="{StaticResource BlueSoft}" Padding="12,8" CornerRadius="8" Margin="0,0,0,8"><TextBlock x:Name="FileSummary" Text="先扫描生成候选。" Foreground="{StaticResource BlueInk}" FontWeight="Medium" TextWrapping="Wrap"/></Border>
     <Border Grid.Row="2" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,8"><Grid>
      <ListView x:Name="CandidatesList" BorderThickness="0" Background="White" SelectionMode="Single" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Standard" ScrollViewer.CanContentScroll="True" ScrollViewer.HorizontalScrollBarVisibility="Auto" AutomationProperties.Name="候选文件表格">
       <ListView.ItemContainerStyle><Style TargetType="ListViewItem"><Setter Property="Height" Value="32"/><Setter Property="Padding" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="BorderBrush" Value="#EEF1F6"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="AutomationProperties.Name" Value="{Binding FileName}"/></Style></ListView.ItemContainerStyle>
       <ListView.View><GridView AllowsColumnReorder="False">
        <GridViewColumn Header="选择" Width="48"><GridViewColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding IsSelected,Mode=TwoWay}" AutomationProperties.Name="{Binding Path}" ToolTip="勾选（跨页保持）" Margin="4,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="文件名" Width="190"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding FileName}" ToolTip="{Binding Path}" Style="{StaticResource Cell}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="目录" Width="300"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Directory}" ToolTip="{Binding Directory}" Style="{StaticResource Cell}" Foreground="#6B7890" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="大小" Width="90"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding SizeText}" Style="{StaticResource Cell}" TextAlignment="Right" MinWidth="74"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="规则" Width="150"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding RuleName}" ToolTip="{Binding RuleName}" Style="{StaticResource Cell}" Foreground="#3D4A63"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="状态" Width="76"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding StateText}" FontWeight="Medium"><TextBlock.Style><Style TargetType="TextBlock" BasedOn="{StaticResource Cell}"><Setter Property="Foreground" Value="#3D4A63"/><Style.Triggers><DataTrigger Binding="{Binding IsKept}" Value="True"><Setter Property="Foreground" Value="#B4630A"/></DataTrigger></Style.Triggers></Style></TextBlock.Style></TextBlock></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
       </GridView></ListView.View>
      </ListView>
      <Border x:Name="CandidatesEmpty" Background="#F7F9FD" CornerRadius="10" Padding="36,40" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"><StackPanel HorizontalAlignment="Center"><TextBlock Text="{G:Files}" Style="{StaticResource Glyph}" FontSize="36" Foreground="#C5D0E0" HorizontalAlignment="Center" Margin="0,0,0,12"/><TextBlock Text="尚无候选文件" FontSize="15" FontWeight="Medium" Foreground="#6B7890" HorizontalAlignment="Center"/><TextBlock Text="先在工作台扫描生成候选。" Style="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,4,0,0"/></StackPanel></Border>
     </Grid></Border>
     <DockPanel Grid.Row="3" Margin="0,0,0,8"><Button x:Name="PreviousButton" Margin="0,0,8,0"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Previous}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="上一页"/></StackPanel></Button><Button x:Name="NextButton" Margin="0,0,8,0"><StackPanel Orientation="Horizontal"><TextBlock Text="下一页"/><TextBlock Text="{G:Next}" Style="{StaticResource Glyph}" Margin="6,0,0,0"/></StackPanel></Button><TextBlock x:Name="PageText" VerticalAlignment="Center" Margin="6,0" Foreground="#6B7890" TextWrapping="NoWrap"/></DockPanel>
     <Border Grid.Row="4" Background="#F7F9FD" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12,8" Margin="0,0,0,12" Height="96"><DockPanel><DockPanel DockPanel.Dock="Top" Margin="0,0,0,4"><TextBlock x:Name="SelectionSummaryText" DockPanel.Dock="Right" Style="{StaticResource Muted}" TextWrapping="NoWrap"/><TextBlock x:Name="DetailHeader" Text="详情" Style="{StaticResource Muted}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/></DockPanel><TextBox x:Name="SelectedPathText" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" IsReadOnly="True" BorderThickness="0" Background="Transparent" TextWrapping="Wrap" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12" Foreground="#3D4A63" Text="选中一个文件后显示完整路径" AutomationProperties.Name="选中文件完整路径"/></DockPanel></Border>
    </Grid>
    <Grid x:Name="RulesPage" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <StackPanel><TextBlock Text="清理规则" Style="{StaticResource Title}"/><TextBlock Text="勾选是草稿，点击“应用范围”后生效；不会添加任意清理路径。选中一行可展开说明和目录。" Style="{StaticResource Muted}" Margin="0,4,0,10"/></StackPanel>
     <Border Grid.Row="1" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,10"><DockPanel><StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="{G:Profile}" Style="{StaticResource Glyph}" Foreground="{StaticResource Blue}" Margin="0,0,8,0"/><TextBlock Text="清理档位" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,16,0"/><RadioButton x:Name="ProfileRecommended" GroupName="CleaningProfile" Content="推荐" IsChecked="True"/><RadioButton x:Name="ProfileDeep" GroupName="CleaningProfile" Content="深度"/></StackPanel><TextBlock x:Name="ProfileHint" Style="{StaticResource Muted}" VerticalAlignment="Center" Margin="8,0,0,0"/></DockPanel></Border>
     <WrapPanel Grid.Row="2" Margin="0,0,0,2">
      <Grid Width="220" Height="32" Margin="0,0,8,8"><TextBox x:Name="RuleSearchBox" VerticalContentAlignment="Center" Padding="26,0,6,0" BorderBrush="#D5DEEB" AutomationProperties.Name="搜索规则"/><TextBlock Text="{G:Search}" Style="{StaticResource Glyph}" FontSize="12" Foreground="#6B7890" Margin="9,0,0,0" IsHitTestVisible="False" HorizontalAlignment="Left"/><TextBlock x:Name="RuleSearchHint" Text="搜索名称、说明或路径" Foreground="#9AA6BA" FontSize="12" Margin="28,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False" TextWrapping="NoWrap"/></Grid>
      <ComboBox x:Name="RuleGroupFilter" Width="150" Height="32" Margin="0,0,8,8" VerticalContentAlignment="Center" AutomationProperties.Name="按分组过滤"/>
      <Button x:Name="RecommendedButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Recommended}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="恢复推荐勾选"/></StackPanel></Button>
      <Button x:Name="SelectGroupButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:SelectAll}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock x:Name="SelectGroupButtonText" Text="全选当前分组"/></StackPanel></Button>
      <Button x:Name="ClearGroupButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:ClearSelection}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock x:Name="ClearGroupButtonText" Text="清空当前分组"/></StackPanel></Button>
     </WrapPanel>
     <Border Grid.Row="3" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,8"><Grid>
      <ListBox x:Name="RulesList" BorderThickness="0" Background="Transparent" ScrollViewer.HorizontalScrollBarVisibility="Disabled" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Standard" ScrollViewer.CanContentScroll="True" AutomationProperties.Name="清理规则列表">
       <ListBox.ItemContainerStyle><Style TargetType="ListBoxItem"><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Padding" Value="0"/><Setter Property="AutomationProperties.Name" Value="{Binding Name}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="RowBorder" Background="Transparent" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="RowBorder" Property="Background" Value="#F7F9FD"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="RowBorder" Property="Background" Value="#EEF4FF"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="RowBorder" Property="BorderBrush" Value="#2F6BFF"/><Setter TargetName="RowBorder" Property="BorderThickness" Value="1"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle>
       <ListBox.ItemTemplate><DataTemplate><Grid>
        <DockPanel Visibility="{Binding HeaderVisibility}" Background="#F3F6FB" MinHeight="34">
         <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="0,0,8,0" VerticalAlignment="Center"><Button Style="{StaticResource LinkButton}" Tag="GroupSelect" ToolTip="勾选此分组全部规则（包括被搜索隐藏的规则）"><TextBlock Text="全选本组"/></Button><Button Style="{StaticResource LinkButton}" Tag="GroupClear" ToolTip="取消勾选此分组全部规则（包括被搜索隐藏的规则）"><TextBlock Text="清空本组"/></Button></StackPanel>
         <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0"><TextBlock Text="{Binding Group}" FontWeight="SemiBold" FontSize="13" TextWrapping="NoWrap"/><TextBlock x:Name="HeaderCount" Text="{Binding CountText}" Style="{StaticResource Muted}" Margin="10,0,0,0" TextWrapping="NoWrap" VerticalAlignment="Center"/></StackPanel>
        </DockPanel>
        <StackPanel Visibility="{Binding RuleVisibility}" Margin="12,0,12,0">
         <Grid MinHeight="34"><Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <CheckBox IsChecked="{Binding Selected,Mode=TwoWay}" VerticalAlignment="Center" AutomationProperties.Name="{Binding Name}" ToolTip="启用（草稿）"/>
          <TextBlock Grid.Column="1" Text="{Binding Name}" FontWeight="Medium" ToolTip="{Binding Name}" Style="{StaticResource Cell}"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
           <Border Background="{StaticResource BlueSoft}" CornerRadius="4" Padding="6,1" Margin="6,0,0,0" Visibility="{Binding RecommendedVisibility}"><TextBlock Text="推荐" Foreground="{StaticResource BlueInk}" FontSize="11" TextWrapping="NoWrap"/></Border>
           <Border Background="#F7F9FD" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="4" Padding="6,1" Margin="6,0,0,0"><TextBlock Text="{Binding RiskText}" Foreground="#6B7890" FontSize="11" TextWrapping="NoWrap"/></Border>
           <Border Background="#F7F9FD" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="4" Padding="6,1" Margin="6,0,0,0"><TextBlock Text="{Binding AgeText}" Foreground="#6B7890" FontSize="11" TextWrapping="NoWrap"/></Border>
           <TextBlock Text="{Binding AvailableShort}" ToolTip="{Binding AvailableText}" Foreground="#6B7890" FontSize="11" Margin="8,0,0,0" Width="64" TextWrapping="NoWrap" VerticalAlignment="Center"/>
          </StackPanel>
         </Grid>
         <StackPanel Margin="28,0,0,8"><StackPanel.Style><Style TargetType="StackPanel"><Setter Property="Visibility" Value="Collapsed"/><Style.Triggers><DataTrigger Binding="{Binding IsSelected,RelativeSource={RelativeSource AncestorType=ListBoxItem}}" Value="True"><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers></Style></StackPanel.Style>
          <TextBlock Text="{Binding Note}" Style="{StaticResource Muted}"/><TextBlock Text="{Binding AvailableText}" Style="{StaticResource Muted}" Margin="0,2,0,0"/><TextBox Text="{Binding Root,Mode=OneWay}" IsReadOnly="True" BorderThickness="0" Background="Transparent" TextWrapping="Wrap" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="11" Foreground="#7A88A0" Margin="0,2,0,0" AutomationProperties.Name="规则目录"/>
         </StackPanel>
        </StackPanel>
       </Grid></DataTemplate></ListBox.ItemTemplate>
      </ListBox>
      <TextBlock x:Name="RulesEmpty" Text="没有匹配的规则。请调整搜索或分组过滤。" Style="{StaticResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
     </Grid></Border>
     <DockPanel Grid.Row="4" Margin="0,0,0,12"><TextBlock x:Name="DraftText" DockPanel.Dock="Bottom" Style="{StaticResource Muted}" Margin="0,0,0,0"/><WrapPanel><Button x:Name="ApplyRulesButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Apply}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="应用范围"/></StackPanel></Button><Button x:Name="CancelRulesButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Discard}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="放弃修改"/></StackPanel></Button><Button x:Name="KeepRuleButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Keep}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="保留此规则全部候选"/></StackPanel></Button><Button x:Name="RestoreRuleButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Unkeep}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="取消保留此规则候选"/></StackPanel></Button></WrapPanel></DockPanel>
    </Grid>
    <Grid x:Name="LogsPage" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><StackPanel Margin="0,0,0,12"><TextBlock Text="任务记录" Style="{StaticResource Title}"/><TextBlock Text="本次会话记录；日志保存在本地私有目录，可能包含完整路径。" Style="{StaticResource Muted}" Margin="0,4,0,0"/></StackPanel>
     <Grid Grid.Row="1"><ListBox x:Name="HistoryList" Margin="0,0,0,12" BorderThickness="0" Background="Transparent" ScrollViewer.HorizontalScrollBarVisibility="Disabled"><ListBox.ItemContainerStyle><Style TargetType="ListBoxItem"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="border" Background="White" CornerRadius="8" Padding="14,10" Margin="0,0,0,8" BorderBrush="#E6EBF3" BorderThickness="1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="{Binding Time}" Foreground="#6B7890" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" VerticalAlignment="Top"/><Border Grid.Column="1" Background="#F7F9FD" CornerRadius="4" Padding="6,2" Margin="8,0" VerticalAlignment="Top"><TextBlock Text="{Binding Action}" Foreground="#3D4A63" FontSize="12" HorizontalAlignment="Center"/></Border><StackPanel Grid.Column="2"><TextBlock Text="{Binding Status}" FontWeight="Medium" Margin="0,0,0,2"/><TextBlock Text="{Binding Summary}" Foreground="#6B7890" TextWrapping="Wrap"/></StackPanel></Grid></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="#D5DEEB"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="{StaticResource Blue}"/><Setter TargetName="border" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle></ListBox><Border x:Name="HistoryEmpty" Background="#F7F9FD" CornerRadius="10" Padding="36,40" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"><StackPanel HorizontalAlignment="Center"><TextBlock Text="{G:Logs}" Style="{StaticResource Glyph}" FontSize="36" Foreground="#C5D0E0" HorizontalAlignment="Center" Margin="0,0,0,12"/><TextBlock Text="尚无任务记录" FontSize="15" FontWeight="Medium" Foreground="#6B7890" HorizontalAlignment="Center"/><TextBlock Text="扫描完成后，任务会在这里显示。" Style="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,4,0,0"/></StackPanel></Border></Grid>
     <WrapPanel Grid.Row="2" Margin="0,0,0,12"><Button x:Name="OpenLogButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:OpenLog}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="打开选中日志"/></StackPanel></Button><Button x:Name="DetailsButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:Details}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="查看任务详情"/></StackPanel></Button><Button x:Name="RemovePreviewButton"><StackPanel Orientation="Horizontal"><TextBlock Text="{G:RemoveRecord}" Style="{StaticResource Glyph}" Margin="0,0,6,0"/><TextBlock Text="删除已放弃的预览记录"/></StackPanel></Button></WrapPanel></Grid>
   </Grid>
   <Border Grid.Row="2" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="20,10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="StatusText" Text="就绪。先扫描预览，不自动删除文件。" Foreground="#6B7890" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/><ProgressBar x:Name="BusyProgress" Grid.Column="1" Width="110" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="12,0,0,0"/></Grid></Border>
  </Grid>
 </Grid>
</Window>
'@
    return (Expand-SjcGuiGlyphs $xaml).Replace('__PRODUCT_VERSION__',(Get-SjcVersion))
}
function Test-SjcGuiProfileSupport {
    # 探测真实引擎档位接口：Set-SjcCleaningProfile -Context -CleaningProfile 与 New-SjcContext -CleaningProfile。
    $set=Get-Command Set-SjcCleaningProfile -CommandType Function -ErrorAction SilentlyContinue
    $new=Get-Command New-SjcContext -CommandType Function -ErrorAction SilentlyContinue
    if(-not $set -or -not $new){return $false}
    return [bool]($set.Parameters.ContainsKey('Context') -and $set.Parameters.ContainsKey('CleaningProfile') -and $new.Parameters.ContainsKey('CleaningProfile'))
}
function Assert-SjcGuiProfileValue {
    param($Profile)
    if($Profile -isnot [string] -or $Profile -cnotin @('Recommended','Deep')){throw '清理档位必须为 Recommended 或 Deep。'}
    return [string]$Profile
}
function Get-SjcGuiContextProfile {
    param($Context)
    $value=Get-SjcGuiValue $Context 'CleaningProfile' 'Recommended'
    if($value -is [string] -and $value -cin @('Recommended','Deep')){return $value};return 'Recommended'
}
function New-SjcGuiState {
    param($Context,[switch]$TestMode)
    $rules=@(Get-SjcRules $Context)
    $selected=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $ruleMap=@{}
    foreach($rule in $rules){if($rule.Recommended){[void]$selected.Add($rule.Id)};$ruleMap[$rule.Id]=$rule}
    $profile=Get-SjcGuiContextProfile $Context
    return @{Context=$Context;Rules=$rules;RuleMap=$ruleMap;Selected=$selected;RecycleMode=$true;Scan=$null;TaskDirectory='';Stale=$true;Excluded=@{};ExcludedRule=@{};CandidateSelection=@{};PageOffset=0;PageSize=200;PageItems=@();History=(New-Object 'System.Collections.Generic.List[object]');Task=$null;LocalJob=$null;Background=$null;Page='Home';TestMode=[bool]$TestMode;Busy=$false;Status='就绪。先扫描预览，不自动删除文件。';LastResult=$null;Draft=@();RuleRows=@();RuleQuery='';RuleGroupFilter='';Closing=$false;PendingScan=$false;PendingApply=$null;Profile=$profile;DraftProfile=$profile;ScanProfile=$profile;ProfileSupported=(Test-SjcGuiProfileSupport);Icon=$null}
}
function New-SjcGuiApp {
    param([Parameter(Mandatory=$true)]$State)
    Initialize-SjcDesktop
    $xamlText=Get-SjcWorkbenchXaml
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($xamlText))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    $ui=@{Window=$window}
    foreach($match in [regex]::Matches($xamlText,'x:Name="([A-Za-z0-9]+)"')){$name=$match.Groups[1].Value;$found=$window.FindName($name);if($found){$ui[$name]=$found}}
    $app=@{State=$State;Ui=$ui;Timer=$null;ResourcesClosed=$false;RuleRefreshPending=$false}
    $window.Tag=$app
    $State.Icon=Get-SjcGuiAppIcon
    if($State.Icon.Window){$window.Icon=$State.Icon.Window}
    if($State.Icon.Brand){$ui.BrandIcon.Source=$State.Icon.Brand}
    $accessible=@{NavHome='工作台';NavFiles='候选文件';NavRules='清理规则';NavLogs='任务记录';ScanButton='开始扫描';ViewFilesButton='查看候选';CancelButton='取消任务';AdjustRulesButton='调整范围';EmptyRecycleButton='清空回收站';KeepButton='保留已勾选';RestoreButton='取消保留已勾选';SelectPageButton='勾选本页';ClearSelectionButton='清除全部勾选';CopyPathButton='复制路径';ExportButton='完整导出 CSV';CleanButton='清理未保留候选';NextButton='下一页';PreviousButton='上一页';RecommendedButton='恢复推荐勾选';SelectGroupButton='全选当前分组';ClearGroupButton='清空当前分组';ApplyRulesButton='应用范围';CancelRulesButton='放弃修改';KeepRuleButton='保留此规则全部候选';RestoreRuleButton='取消保留此规则候选';OpenLogButton='打开选中日志';DetailsButton='查看任务详情';RemovePreviewButton='删除已放弃的预览记录'}
    foreach($name in @($accessible.Keys)){
        $ui[$name].Tag=@{App=$app;Name=$name}
        [Windows.Automation.AutomationProperties]::SetName($ui[$name],$accessible[$name])
        $ui[$name].Add_Click({param($sender,$event) try{Invoke-SjcGuiCommand $sender.Tag.App $sender.Tag.Name}catch{Set-SjcGuiStatus $sender.Tag.App ('操作失败: '+$_.Exception.Message)}})
    }
    $ui.RecycleMode.Tag=$app
    $ui.RecycleMode.Add_Click({param($sender,$event) $app=$sender.Tag;if(-not $app.State.Busy){$app.State.RecycleMode=[bool]$sender.IsChecked;Save-SjcGuiPreferences $app;Update-SjcGuiView $app}})
    $ui.CandidatesList.Tag=$app
    $ui.CandidatesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiCandidateSelection $sender.Tag $event.OriginalSource})
    $ui.CandidatesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiCandidateSelection $sender.Tag $event.OriginalSource})
    $ui.CandidatesList.Add_SelectionChanged({param($sender,$event) Update-SjcGuiCandidateDetail $sender.Tag})
    $ui.CandidatesList.Add_SizeChanged({param($sender,$event) Resize-SjcGuiCandidateColumns $sender})
    $ui.RulesList.Tag=$app
    $ui.RulesList.Add_SelectionChanged({param($sender,$event) $row=$sender.SelectedItem;if($row){Update-SjcGuiGroupButtons $sender.Tag;if($row.Kind -eq 'Rule'){Set-SjcGuiStatus $sender.Tag ('当前规则：'+$row.Name+' · '+$row.Group+'。勾选框是启用草稿，与当前选中行相互独立。')}}})
    $ui.RulesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiRuleDraftCheck $sender.Tag $event.OriginalSource})
    $ui.RulesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiRuleDraftCheck $sender.Tag $event.OriginalSource})
    $ui.RulesList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$event) $button=$event.OriginalSource;if($button -is [Windows.Controls.Button] -and $button.Tag -in @('GroupSelect','GroupClear') -and $button.DataContext){$event.Handled=$true;try{Set-SjcGuiDraftGroup $sender.Tag ([string]$button.DataContext.Group) ($button.Tag -eq 'GroupSelect')}catch{Set-SjcGuiStatus $sender.Tag ('操作失败: '+$_.Exception.Message)}}})
    $ui.RuleSearchBox.Tag=$app
    $ui.RuleSearchBox.Add_TextChanged({param($sender,$event) $app=$sender.Tag;$app.State.RuleQuery=[string]$sender.Text;$app.Ui.RuleSearchHint.Visibility=if($sender.Text){'Collapsed'}else{'Visible'};Update-SjcGuiRuleRows $app})
    $ui.RuleGroupFilter.Tag=$app
    $groups=New-Object 'System.Collections.Generic.List[string]';foreach($rule in $State.Rules){if(-not $groups.Contains([string]$rule.Group)){[void]$groups.Add([string]$rule.Group)}}
    [void]$ui.RuleGroupFilter.Items.Add('全部分组');foreach($group in $groups){[void]$ui.RuleGroupFilter.Items.Add($group)};$ui.RuleGroupFilter.SelectedIndex=0
    $ui.RuleGroupFilter.Add_SelectionChanged({param($sender,$event) $app=$sender.Tag;$app.State.RuleGroupFilter=if($sender.SelectedIndex -le 0){''}else{[string]$sender.SelectedItem};Update-SjcGuiRuleRows $app})
    foreach($name in @('ProfileRecommended','ProfileDeep')){$ui[$name].Tag=$app;$ui[$name].Add_Checked({param($sender,$event) $app=$sender.Tag;if(-not $sender.IsChecked){return};$value=if($sender.Name -eq 'ProfileDeep'){'Deep'}else{'Recommended'};if($value -ceq $app.State.DraftProfile){return};$app.State.DraftProfile=$value;Update-SjcGuiDraftAges $app;Update-SjcGuiProfile $app;Update-SjcGuiDraftText $app})}
    $window.Add_Closing({param($sender,$event) $app=$sender.Tag;if($app.State.Busy){$event.Cancel=$true;Request-SjcGuiCancel $app;Set-SjcGuiStatus $app '正在取消。请等待后台任务结束后再关闭窗口。'}else{Remove-SjcGuiApp $app}})
    $window.Add_Closed({param($sender,$event) Remove-SjcGuiApp $sender.Tag})
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $tick={param($sender,$event) try{Invoke-SjcGuiTick $app}catch{Set-SjcGuiStatus $app ('后台反馈失败: '+$_.Exception.Message)}}.GetNewClosure()
    $timer.Add_Tick($tick)
    $app.Timer=$timer;$timer.Start()
    Set-SjcGuiDraft $app
    Set-SjcGuiPage $app 'Home'
    Update-SjcGuiView $app
    return $app
}
function Set-SjcGuiStatus {
    param($App,[string]$Text)
    $App.State.Status=$Text;$App.Ui.StatusText.Text=$Text;$App.Ui.StatusText.ToolTip=$Text
}
function Set-SjcGuiPage {
    param($App,[ValidateSet('Home','Files','Rules','Logs')][string]$Page)
    $App.State.Page=$Page
    foreach($name in @('Home','Files','Rules','Logs')){
        $App.Ui[($name+'Page')].Visibility=if($name -eq $Page){'Visible'}else{'Collapsed'}
        $App.Ui[('Nav'+$name)].Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($name -eq $Page){'#EAF1FF'}else{'White'}))
        $App.Ui[('Nav'+$name)].Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($name -eq $Page){'#1C3F9E'}else{'#3D4A63'}))
    }
    $label=@{Home='工作台';Files='候选文件';Rules='清理规则';Logs='任务记录'}[$Page]
    $App.Ui.Breadcrumb.Text='星梦雨垃圾清理器  /  '+$label
}
function Set-SjcGuiDraft {
    param($App)
    $App.State.Draft=@($App.State.Rules|ForEach-Object{
        [pscustomobject]@{
            Kind='Rule'
            Id=$_.Id
            Selected=$App.State.Selected.Contains($_.Id)
            Name=$_.Name
            Root=$_.Root
            Note=$_.Note
            Risk=$_.Risk
            RiskText=('风险 '+$_.Risk)
            Group=$_.Group
            RecommendedAge=[double](Get-SjcGuiValue $_ 'RecommendedMinimumAgeHours' $_.MinimumAgeHours)
            DeepAge=[double](Get-SjcGuiValue $_ 'DeepMinimumAgeHours' $_.MinimumAgeHours)
            AgeText=('≥ '+[string]$_.MinimumAgeHours+' 小时')
            AvailableText=$(if($_.Available){'目录存在。'}else{'目录不存在，扫描时跳过。'})
            AvailableShort=$(if($_.Available){'目录存在'}else{'目录不存在'})
            Recommended=$_.Recommended
            RecommendedVisibility=$(if($_.Recommended){'Visible'}else{'Collapsed'})
            HeaderVisibility='Collapsed'
            RuleVisibility='Visible'
            CountText=''
        }
    })
    $App.State.DraftProfile=$App.State.Profile
    Update-SjcGuiDraftAges $App -NoRefresh
    Update-SjcGuiRuleRows $App
    Update-SjcGuiProfile $App
}
function Update-SjcGuiDraftAges {
    # 规则草稿按“草稿档位”显示对应年龄阈值；仅显示，不改变已生效的引擎规则。
    param($App,[switch]$NoRefresh)
    $s=$App.State
    foreach($row in @($s.Draft)){
        $hours=if($s.DraftProfile -ceq 'Deep'){$row.DeepAge}else{$row.RecommendedAge}
        $row.AgeText=('≥ '+[string]$hours+' 小时'+$(if($s.DraftProfile -cne $s.Profile){'（草稿）'}else{''}))
    }
    if(-not $NoRefresh -and $App.Ui.RulesList){$App.Ui.RulesList.Items.Refresh()}
}
function Complete-SjcGuiProfileApply {
    # 真正切档：旧预览已释放后调用。Context.CleaningProfile 只能经 Set-SjcCleaningProfile 改变（无返回值，内部重建 Context.Rules）。
    param($App,[string]$Profile,[string[]]$SelectedIds)
    $s=$App.State
    $Profile=Assert-SjcGuiProfileValue $Profile
    Set-SjcCleaningProfile -Context $s.Context -CleaningProfile $Profile
    $actual=Get-SjcGuiContextProfile $s.Context
    if($actual -cne $Profile){throw '引擎档位未切换成功。'}
    $s.Rules=@($s.Context.Rules);if($s.Rules.Count -eq 0){$s.Rules=@(Get-SjcRules $s.Context)}
    $s.RuleMap=@{};foreach($rule in $s.Rules){$s.RuleMap[$rule.Id]=$rule}
    # 保持用户选择的规则 ID，不自动扩选推荐项；仅剔除新规则集中不存在的 ID。
    $s.Selected.Clear();foreach($id in @($SelectedIds)){if($s.RuleMap.ContainsKey($id)){[void]$s.Selected.Add($id)}}
    $s.Profile=$actual;$s.DraftProfile=$actual
    $s.Scan=$null;$s.TaskDirectory='';$s.PageItems=@();$s.PageOffset=0;$s.CandidateSelection.Clear();$s.Excluded.Clear();$s.ExcludedRule.Clear();$s.Stale=$true
    if($App.Ui.CandidatesList){$App.Ui.CandidatesList.SelectedItem=$null}
    Save-SjcGuiPreferences $App
    Set-SjcGuiDraft $App
    Set-SjcGuiStatus $App ('范围已应用：'+$s.Selected.Count+' 条规则，档位已切换为'+(Get-SjcGuiProfileLabel $actual)+'。旧扫描与保留已清空，需重新扫描。')
    Update-SjcGuiView $App
}
function Test-SjcGuiRuleMatch {
    param($Row,[string]$Query,[string]$Group)
    if($Group -and $Row.Group -ne $Group){return $false}
    if([string]::IsNullOrWhiteSpace($Query)){return $true}
    $q=$Query.Trim()
    foreach($value in @($Row.Name,$Row.Group,$Row.Note,$Row.Root,$Row.Id)){if($value -and ([string]$value).IndexOf($q,[StringComparison]::OrdinalIgnoreCase) -ge 0){return $true}}
    return $false
}
function Get-SjcGuiGroupCountText {
    param($App,[string]$Group,[int]$Visible)
    $all=@($App.State.Draft|Where-Object{$_.Group -eq $Group})
    $checked=@($all|Where-Object Selected).Count
    $text=('已勾选 {0} / {1}' -f $checked,$all.Count)
    if($Visible -lt $all.Count){$text+=('  ·  当前显示 {0}' -f $Visible)}
    return $text
}
# 可见分组：分组标题行 + 规则行组成的扁平虚拟化列表；规则行就是 Draft 对象本身。
function Update-SjcGuiRuleRows {
    param($App)
    $s=$App.State;$u=$App.Ui
    $previous=$u.RulesList.SelectedItem
    $order=New-Object 'System.Collections.Generic.List[string]'
    foreach($row in $s.Draft){if(-not $order.Contains([string]$row.Group)){[void]$order.Add([string]$row.Group)}}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($group in $order){
        $hits=@($s.Draft|Where-Object{$_.Group -eq $group -and (Test-SjcGuiRuleMatch $_ $s.RuleQuery $s.RuleGroupFilter)})
        if($hits.Count -eq 0){continue}
        [void]$rows.Add([pscustomobject]@{Kind='Header';Id=('group:'+$group);Group=$group;Name=('分组 '+$group);VisibleCount=$hits.Count;CountText=(Get-SjcGuiGroupCountText $App $group $hits.Count);HeaderVisibility='Visible';RuleVisibility='Collapsed';Selected=$false;Root='';Note='';RiskText='';AgeText='';AvailableText='';AvailableShort='';RecommendedVisibility='Collapsed'})
        foreach($match in $hits){[void]$rows.Add($match)}
    }
    $s.RuleRows=$rows.ToArray()
    $u.RulesList.ItemsSource=$s.RuleRows
    if($previous){
        if($previous.Kind -eq 'Rule' -and $s.RuleRows -contains $previous){$u.RulesList.SelectedItem=$previous}
        elseif($previous.Kind -eq 'Header'){$again=@($s.RuleRows|Where-Object{$_.Kind -eq 'Header' -and $_.Group -eq $previous.Group});if($again.Count){$u.RulesList.SelectedItem=$again[0]}}
    }
    if($u.RulesEmpty){$u.RulesEmpty.Visibility=if($s.RuleRows.Count -eq 0){'Visible'}else{'Collapsed'}}
    Update-SjcGuiGroupButtons $App
    Update-SjcGuiDraftText $App
}
function Update-SjcGuiRuleHeaders {
    param($App,[switch]$Refresh)
    $s=$App.State;$u=$App.Ui
    foreach($row in @($s.RuleRows|Where-Object Kind -eq 'Header')){
        $row.CountText=Get-SjcGuiGroupCountText $App $row.Group $row.VisibleCount
        if(-not $Refresh){
            $container=$u.RulesList.ItemContainerGenerator.ContainerFromItem($row)
            if($container){$label=Find-SjcGuiNamedChild $container 'HeaderCount';if($label){$label.Text=$row.CountText}}
        }
    }
    if($Refresh){$u.RulesList.Items.Refresh()}
    Update-SjcGuiDraftText $App
}
function Set-SjcGuiRuleDraftCheck {
    param($App,$CheckBox)
    if($null -eq $CheckBox -or $CheckBox -isnot [Windows.Controls.CheckBox]){return}
    $row=$CheckBox.DataContext
    if($null -eq $row -or -not $row.PSObject.Properties['Kind'] -or $row.Kind -ne 'Rule'){return}
    $row.Selected=[bool]$CheckBox.IsChecked
    Update-SjcGuiRuleHeaders $App
}
function Get-SjcGuiCurrentGroup {
    param($App)
    $current=$App.Ui.RulesList.SelectedItem
    if($current){return [string]$current.Group}
    return ''
}
function Update-SjcGuiGroupButtons {
    param($App)
    $u=$App.Ui;$group=Get-SjcGuiCurrentGroup $App
    if(-not $u.SelectGroupButtonText){return}
    if($group){
        $count=@($App.State.Draft|Where-Object{$_.Group -eq $group}).Count
        $u.SelectGroupButtonText.Text=('全选“{0}”({1})' -f $group,$count);$u.ClearGroupButtonText.Text=('清空“{0}”' -f $group)
        $u.SelectGroupButton.ToolTip=('勾选分组“'+$group+'”全部 '+$count+' 条规则，包括被搜索隐藏的规则；应用范围后生效。');$u.ClearGroupButton.ToolTip=('取消勾选分组“'+$group+'”全部规则，包括被搜索隐藏的规则。')
    }else{
        $u.SelectGroupButtonText.Text='全选当前分组';$u.ClearGroupButtonText.Text='清空当前分组'
        $u.SelectGroupButton.ToolTip='先选中一条规则或分组标题';$u.ClearGroupButton.ToolTip='先选中一条规则或分组标题'
    }
    if(-not $App.State.Busy){$u.SelectGroupButton.IsEnabled=[bool]$group;$u.ClearGroupButton.IsEnabled=[bool]$group}
    $rule=$u.RulesList.SelectedItem
    if($u.KeepRuleButton -and -not $App.State.Busy){$ok=($rule -and $rule.Kind -eq 'Rule' -and (Test-SjcGuiCleanable $App.State));$u.KeepRuleButton.IsEnabled=[bool]$ok;$u.RestoreRuleButton.IsEnabled=[bool]$ok}
}
function Set-SjcGuiDraftGroup {
    param($App,[string]$Group,[bool]$Selected)
    if(-not $Group){return}
    if($App.State.Busy){throw '请等待当前任务结束。'}
    $count=0
    foreach($item in $App.State.Draft){if($item.Group -eq $Group){$item.Selected=$Selected;$count++}}
    Update-SjcGuiRuleHeaders $App -Refresh
    Set-SjcGuiStatus $App ($(if($Selected){'已勾选'}else{'已取消勾选'})+'分组“'+$Group+'”全部 '+$count+' 条规则（含被搜索隐藏的规则）。草稿需“应用范围”后生效。')
}
function Update-SjcGuiDraftText {
    param($App)
    $s=$App.State;$u=$App.Ui
    if(-not $u.DraftText){return}
    $checked=@($s.Draft|Where-Object Selected)
    $changed=@($s.Draft|Where-Object{$_.Selected -ne $s.Selected.Contains($_.Id)}).Count
    $profileChanged=($s.DraftProfile -ne $s.Profile)
    $text=('草稿：勾选 {0} / {1} 条规则；当前生效 {2} 条。' -f $checked.Count,$s.Draft.Count,$s.Selected.Count)
    if($changed -or $profileChanged){$text+=('有未应用的修改（规则 {0} 处{1}），应用后需重新扫描。' -f $changed,$(if($profileChanged){'，档位'}else{''}))}else{$text+='草稿与生效范围一致。'}
    $u.DraftText.Text=$text
}
function Get-SjcGuiProfileLabel {
    param([string]$Profile)
    if($Profile -eq 'Deep'){return '深度'};return '推荐'
}
function Update-SjcGuiProfile {
    param($App)
    $s=$App.State;$u=$App.Ui
    if(-not $u.ProfileDeep){return}
    $u.ProfileRecommended.IsChecked=($s.DraftProfile -ne 'Deep');$u.ProfileDeep.IsChecked=($s.DraftProfile -eq 'Deep')
    $u.ProfileDeep.IsEnabled=($s.ProfileSupported -and -not $s.Busy);$u.ProfileRecommended.IsEnabled=(-not $s.Busy)
    if(-not $s.ProfileSupported){$u.ProfileHint.Text='当前引擎仅提供推荐档；深度档待引擎接口接入后可用。';$u.ProfileDeep.ToolTip='引擎尚未提供深度档'}
    elseif($s.DraftProfile -eq 'Deep'){$u.ProfileHint.Text='深度：扩大到已核实但影响更大的缓存；风险项不会自动全选。切换后需重新扫描，清理前逐类确认影响。';$u.ProfileDeep.ToolTip=$null}
    else{$u.ProfileHint.Text='推荐：仅低影响的常见缓存与临时文件。切换档位后需重新扫描。';$u.ProfileDeep.ToolTip=$null}
}
function Save-SjcGuiPreferences {
    param($App)
    if($App.State.TestMode){return}
    try{[void](Save-SjcPreferences -Context $App.State.Context -Preferences ([pscustomobject]@{RecycleMode=[bool]$App.State.RecycleMode;SelectedRuleIds=[string[]]@($App.State.Selected);CleaningProfile=[string](Get-SjcGuiContextProfile $App.State.Context)}))}
    catch{Set-SjcGuiStatus $App ('设置未能保存，本次会话仍可使用：'+$_.Exception.Message)}
}
function Test-SjcGuiCleanable {
    param($State)
    return ($null -ne $State.Scan -and -not $State.Stale -and $State.Scan.Status -in @('Success','Partial') -and $State.Scan.CandidateCount -gt 0)
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
    $row.IsSelected=[bool]$CheckBox.IsChecked
    if($row.IsSelected){$App.State.CandidateSelection[$row.Id]=[pscustomobject]@{Path=$row.Path;Length=[int64]$row.Length;RuleId=$row.RuleId}}else{$App.State.CandidateSelection.Remove($row.Id)}
    # 用户实际操作的勾选框所在行成为当前行，详情与勾选保持一致；容器复用触发的事件不改变当前行。
    if(($CheckBox.IsKeyboardFocusWithin -or $CheckBox.IsMouseOver) -and $App.Ui.CandidatesList.Items.Contains($row)){$App.Ui.CandidatesList.SelectedItem=$row}
    Update-SjcGuiFileChrome $App
}
function Update-SjcGuiCandidateDetail {
    param($App)
    $s=$App.State;$u=$App.Ui
    if(-not $u.SelectedPathText){return}
    $current=$u.CandidatesList.SelectedItem
    $checkedCount=$s.CandidateSelection.Count
    if($current){
        $u.DetailHeader.Text=('当前行  ·  {0}  ·  {1}  ·  {2}{3}' -f $current.RuleName,$current.SizeText,$current.StateText,$(if($current.Modified){'  ·  修改于 '+$current.Modified}else{''}))
        $u.SelectedPathText.Text=$current.Path
    }elseif($checkedCount -gt 0){
        $paths=@($s.CandidateSelection.Values|Select-Object -First 50|ForEach-Object Path)
        $u.DetailHeader.Text=('已勾选文件完整路径（{0} 个{1}）' -f $checkedCount,$(if($checkedCount -gt 50){'，显示前 50 个'}else{''}))
        $u.SelectedPathText.Text=($paths -join "`r`n")
    }else{
        $u.DetailHeader.Text='详情'
        $u.SelectedPathText.Text='选中一个文件后显示完整路径'
    }
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
    $u.SelectionSummaryText.Text=if($checked){('已勾选 {0} 个（本页 {1}，其他页 {2}）' -f $checked,$onPage,($checked-$onPage))}else{'未勾选'}
    if($cleanable){
        $pending=[int64]$s.Scan.CandidateCount-$s.Excluded.Count
        $pendingBytes=[int64]$s.Scan.CandidateBytes-(Get-SjcGuiExcludedBytes $s)
        $u.CleanButtonText.Text=('清理全部未保留 ({0:N0})…' -f $pending)
        $u.FileSummary.Text=('候选 {0:N0} 个  ·  已保留 {1:N0} 个  ·  将处理全部未保留 {2:N0} 个（{3}），不限于勾选  ·  模式：{4}' -f $s.Scan.CandidateCount,$s.Excluded.Count,$pending,(Format-SjcGuiSize $pendingBytes),$(if($s.RecycleMode){'移入回收站（不等于释放空间）'}else{'永久删除'}))
    }else{$u.CleanButtonText.Text='清理未保留候选…'}
    Update-SjcGuiCandidateDetail $App
}
function Resize-SjcGuiCandidateColumns {
    param($List)
    if(-not $List -or -not $List.View -or $List.ActualWidth -le 0){return}
    # 列：选择/文件名/目录/大小/规则/状态。窄窗口先压缩文件名、规则和目录，保证状态列始终可见。
    $columns=$List.View.Columns
    $available=$List.ActualWidth-26
    $columns[0].Width=44;$columns[3].Width=88;$columns[5].Width=72
    $rest=$available-44-88-72
    $name=[math]::Max(130,[math]::Min(220,[math]::Floor($rest*0.30)))
    $rule=[math]::Max(110,[math]::Min(170,[math]::Floor($rest*0.22)))
    $columns[1].Width=$name;$columns[4].Width=$rule
    $columns[2].Width=[math]::Max(120,$rest-$name-$rule)
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
    $s=$App.State;$u=$App.Ui;$idle=-not $s.Busy;$cleanable=Test-SjcGuiCleanable $s
    $u.ScopeText.Text=('已应用 {0} / {1} 条规则  ·  档位：{2}  ·  {3}' -f $s.Selected.Count,$s.Rules.Count,(Get-SjcGuiProfileLabel $s.Profile),$(if($s.RecycleMode){'移入回收站'}else{'永久删除'}))
    foreach($name in @('ScanButton','AdjustRulesButton','RecycleMode','EmptyRecycleButton','ApplyRulesButton','RecommendedButton','SelectGroupButton','ClearGroupButton','CancelRulesButton','RulesList','RemovePreviewButton','RuleSearchBox','RuleGroupFilter')){$u[$name].IsEnabled=$idle}
    $u.ScanButton.IsEnabled=$idle -and $s.Selected.Count -gt 0
    foreach($name in @('KeepRuleButton','RestoreRuleButton','CleanButton','ExportButton')){$u[$name].IsEnabled=$idle -and $cleanable}
    $u.CancelButton.Visibility=if($s.Busy){'Visible'}else{'Collapsed'}
    $u.CancelButton.IsEnabled=$s.Busy
    $u.BusyProgress.Visibility=if($s.Busy){'Visible'}else{'Collapsed'}
    $u.PreviousButton.IsEnabled=$idle -and $null -ne $s.Scan -and $s.PageOffset -gt 0
    $u.NextButton.IsEnabled=$idle -and $null -ne $s.Scan -and ($s.PageOffset+$s.PageSize) -lt $s.Scan.CandidateCount
    if($s.Scan -and -not $s.Stale){
        $u.MetricBytes.Text=Format-SjcGuiSize $s.Scan.CandidateBytes;$u.MetricCount.Text=('{0:N0}' -f $s.Scan.CandidateCount);$u.MetricKept.Text=[string]$s.Excluded.Count
        $u.PendingText.Text=('清理时将处理 {0:N0} 个未保留候选' -f ($s.Scan.CandidateCount-$s.Excluded.Count))
        $first=$s.PageOffset+1;$last=[math]::Min($s.PageOffset+$s.PageSize,[int64]$s.Scan.CandidateCount)
        $u.PageText.Text=('第 {0} / {1} 页  ·  第 {2:N0}–{3:N0} 条，共 {4:N0} 条  ·  每页 {5} 条' -f ([math]::Floor($s.PageOffset/$s.PageSize)+1),[math]::Max(1,[math]::Ceiling($s.Scan.CandidateCount/$s.PageSize)),$first,$last,$s.Scan.CandidateCount,$s.PageSize)
    }else{
        foreach($name in @('MetricBytes','MetricCount','MetricKept')){$u[$name].Text='—'}
        $u.PendingText.Text=if($s.Scan){'需重新扫描'}else{'尚未扫描'}
        $u.FileSummary.Text=if($s.Scan){'旧扫描快照已失效，需重新扫描。'}else{'先扫描生成候选。'};$u.PageText.Text=''
    }
    $currentId=if($u.CandidatesList.SelectedItem){$u.CandidatesList.SelectedItem.Id}else{$null}
    $rows=@(Get-SjcGuiCandidateRows $s)
    $u.CandidatesList.ItemsSource=$rows
    if($currentId){$again=@($rows|Where-Object{$_.Id -eq $currentId});if($again.Count){$u.CandidatesList.SelectedItem=$again[0]}}
    if($u.CandidatesEmpty){$u.CandidatesEmpty.Visibility=if($rows.Count -eq 0){'Visible'}else{'Collapsed'}}
    Update-SjcGuiFileChrome $App
    $categories=if($s.Scan){@($s.Scan.Categories)}else{@($s.Rules|Where-Object{$s.Selected.Contains($_.Id)}|ForEach-Object{[pscustomobject]@{Name=$_.Name;Count=0;Bytes=0;Status='Pending';RuleId=$_.Id}})}
    $u.CategoryList.ItemsSource=@($categories|ForEach-Object{
        $status=@{Success='已扫描';Partial='部分完成（已发现量）';Missing='目录不存在，跳过';RunningProcess='应用运行中，跳过';Failed='读取失败';Cancelled='扫描已取消';Pending='尚未扫描';UnsupportedConfiguration='检测到自定义缓存配置，未扫描'}[[string]$_.Status]
        if(-not $status){$status=[string]$_.Status}
        [pscustomobject]@{Name=$_.Name;StatusText=$status;SizeText=$(if($_.Status -in @('Success','Partial')){Format-SjcGuiSize $_.Bytes}else{'—'});CountText=$(if($_.Status -in @('Success','Partial')){[string]$_.Count+' 个文件'}else{'未统计'})}
    })
    $historySelection=$u.HistoryList.SelectedItem
    $u.HistoryList.ItemsSource=@($s.History.ToArray())
    if($historySelection){$u.HistoryList.SelectedItem=$historySelection}
    if($u.HistoryEmpty){$u.HistoryEmpty.Visibility=if($s.History.Count -eq 0){'Visible'}else{'Collapsed'}}
    Update-SjcGuiProfile $App
    Update-SjcGuiDraftText $App
    Update-SjcGuiGroupButtons $App
    Set-SjcGuiStatus $App $s.Status
}
function Show-SjcGuiDetails {
    param($App,[string]$Text)
    $window=[Windows.Window]::new();$window.Title='任务详情';$window.Width=760;$window.Height=480;$window.Owner=$App.Ui.Window;$window.WindowStartupLocation='CenterOwner'
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
    $pending=[int64]$s.Scan.CandidateCount-$s.Excluded.Count
    $bytes=[int64]$s.Scan.CandidateBytes-(Get-SjcGuiExcludedBytes $s)
    return [pscustomobject]@{PendingCount=$pending;PendingBytes=$bytes;KeptCount=$s.Excluded.Count;CheckedCount=$s.CandidateSelection.Count;RecycleMode=[bool]$s.RecycleMode;Profile=$(if($s.ScanProfile){$s.ScanProfile}else{'Recommended'});ProfileSupported=[bool]$s.ProfileSupported;Rows=$rows.ToArray()}
}
function New-SjcGuiCleanConfirmWindow {
    param($App,$Summary)
    $mode=if($Summary.RecycleMode){'移入回收站：可从回收站还原；通常不会立即释放磁盘空间。'}else{'永久删除：不经过回收站，无法从回收站恢复。'}
    $profile=if($Summary.ProfileSupported){Get-SjcGuiProfileLabel $Summary.Profile}else{'推荐（当前引擎仅提供此档）'}
    $checkedNote=if($Summary.CheckedCount){'勾选的 '+$Summary.CheckedCount+' 个文件只用于保留/复制等批量操作，不限定清理范围。'}else{'清理范围不取决于勾选。'}
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="确认清理范围" Width="880" Height="560" MinWidth="720" MinHeight="420" WindowStartupLocation="CenterOwner" FontFamily="Microsoft YaHei UI" FontSize="13" Background="White" Foreground="#16213A" ShowInTaskbar="False" UseLayoutRounding="True">
 <Border Padding="18"><DockPanel>
  <StackPanel DockPanel.Dock="Top">
   <TextBlock x:Name="Headline" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
   <Grid Margin="0,10,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
    <TextBlock Text="处理方式" Foreground="#6B7890"/><TextBlock x:Name="ModeText" Grid.Column="1" TextWrapping="Wrap" FontWeight="Medium"/>
    <TextBlock Grid.Row="1" Text="清理档位" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="ProfileText" Grid.Row="1" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <TextBlock Grid.Row="2" Text="保留" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="KeptText" Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <TextBlock Grid.Row="3" Text="勾选" Foreground="#6B7890" Margin="0,4,0,0"/><TextBlock x:Name="CheckedText" Grid.Row="3" Grid.Column="1" TextWrapping="Wrap" Margin="0,4,0,0"/>
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
    $window.FindName('ScopeTable').ItemsSource=@($Summary.Rows)
    $accept=$window.FindName('AcceptConfirm')
    $accept.Content=if($Summary.RecycleMode){'移入回收站'}else{'永久删除'}
    $accept.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Summary.RecycleMode){'#2F6BFF'}else{'#C2342B'}))
    $accept.Tag=$window
    $accept.Add_Click({param($sender,$event) $sender.Tag.DialogResult=$true})
    return $window
}
function Confirm-SjcGuiClean {
    param($App,$Summary)
    if($App.State.TestMode){return $false}
    $window=New-SjcGuiCleanConfirmWindow $App $Summary
    $window.Owner=$App.Ui.Window
    return ([bool]$window.ShowDialog())
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
 'RuleKeep' { $Token.ThrowIfCancellationRequested();[pscustomobject]@{Items=@(Get-SjcPreviewRuleCandidates $Shared.Preview $Arguments.RuleId)} }
 'Export' { $Token.ThrowIfCancellationRequested();Export-SjcCandidates -PlanPath $Arguments.PlanPath -Destination $Arguments.Destination -ExcludedIds $Arguments.ExcludedIds -CancellationToken $Token }
 'Close' { if($Shared.Preview){Close-SjcPreviewSession $Shared.Preview;$Shared.Preview=$null};[pscustomobject]@{Closed=$true} }
}
'@
    $power=[PowerShell]::Create();$power.Runspace=$background.Runspace
    $cancel=[Threading.CancellationTokenSource]::new()
    [void]$power.AddScript($source).AddArgument($background.Shared).AddArgument($Kind).AddArgument($Arguments).AddArgument($cancel.Token)
    $handle=$power.BeginInvoke()
    $App.State.LocalJob=@{Kind=$Kind;Arguments=$Arguments;PowerShell=$power;Handle=$handle;Cancel=$cancel}
    $label=@{Open='打开候选预览';Page='读取分页';RuleKeep='按规则更新保留';Export='完整导出 CSV';Close='释放旧预览'}[$Kind]
    $App.State.Busy=$true;Set-SjcGuiStatus $App ('正在后台'+$label+'，界面仍可切换页面。');Update-SjcGuiView $App
}
function Start-SjcGuiTask {
    param($App,[ValidateSet('Scan','Clean','Recycle')][string]$Action)
    $s=$App.State
    if($s.Busy){throw '已有任务正在运行。'}
    if($s.TestMode){throw '隔离界面模式不允许启动生产 Worker。'}
    if($s.PendingApply){throw '档位切换尚未完成。'}
    $profile=Assert-SjcGuiProfileValue $s.Profile
    if($Action -in @('Scan','Clean') -and (Get-SjcGuiContextProfile $s.Context) -cne $profile){throw '界面档位与引擎上下文不一致，请重新应用范围。'}
    if($Action -eq 'Scan'){$task=New-SjcTaskDirectory $s.Context}else{if($Action -eq 'Clean'){$task=$s.TaskDirectory}else{$task=New-SjcTaskDirectory $s.Context}}
    $id=[guid]::NewGuid().ToString('N').Substring(0,8);$prefix='gui-'+$Action.ToLower()+'-'+$id
    $payloadPath=Join-Path $task ($prefix+'.payload.json');$outputPath=Join-Path $task ($prefix+'.output.json');$progress=Join-Path $task ($prefix+'.progress.json');$cancel=Join-Path $task ($prefix+'.cancel')
    $payload=[ordered]@{TaskDirectory=$task;ProgressPath=$progress;CancelPath=$cancel}
    if($Action -eq 'Scan'){
        $payload.RuleIds=[string[]]@($s.Selected)
    }
    if($Action -eq 'Clean'){$payload.ExcludedIds=[string[]]@($s.Excluded.Keys);$payload.RecycleMode=[bool]$s.RecycleMode}
    if($Action -in @('Scan','Clean')){$payload.CleaningProfile=$profile}
    Write-SjcAtomicText $payloadPath ($payload|ConvertTo-Json -Depth 5 -Compress) -NoOverwrite
    $spec=Get-SjcGuiLaunchSpec $Action $payloadPath $outputPath
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$spec.FileName;$info.Arguments=$spec.Arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try{if(-not $process.Start()){throw '无法启动后台进程。'}}catch{$process.Dispose();throw}
    $s.Task=@{Action=$Action;TaskDirectory=$task;Process=$process;OutputPath=$outputPath;ProgressPath=$progress;CancelPath=$cancel;CancelRequested=$false;CancelAt=$null;Forced=$false;RuleIds=[string[]]@($s.Selected);Profile=$s.Profile}
    $s.Busy=$true;if($Action -eq 'Scan'){$s.Scan=$null;$s.Stale=$true;$s.PageItems=@();$s.Excluded.Clear();$s.ExcludedRule.Clear();$s.CandidateSelection.Clear()}
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
    $record=[pscustomobject]@{Time=(Get-Date -Format 'MM-dd HH:mm:ss');Action=$action;Status=$label;Summary=$summary;LogPath=[string](Get-SjcGuiValue $Result 'LogPath' '');TaskDirectory=$task.TaskDirectory;Result=$Result}
    $s.History.Insert(0,$record);$App.Ui.LastTaskText.Text=$record.Time+' · '+$label+' · '+$summary
    if($action -eq 'Scan'){
        $s.Scan=$Result;$s.TaskDirectory=$task.TaskDirectory;$s.Stale=($status -notin @('Success','Partial'));$s.PageOffset=0
        $s.ScanProfile=if($task.ContainsKey('Profile') -and $task.Profile){[string]$task.Profile}else{'Recommended'}
        if(-not $s.Stale -and $Result.CandidateCount -gt 0){Start-SjcGuiLocalJob $App 'Open' @{PlanPath=$Result.PlanPath}}
    }elseif($action -eq 'Clean'){$s.Stale=$true;$s.PageItems=@()}
    $errorText=[string](Get-SjcGuiValue $Result 'Error' '')
    Set-SjcGuiStatus $App ($label+'：'+$summary+$(if($errorText){'；'+$errorText}else{''})+$(if($action -eq 'Clean'){'。需重新扫描；回收站移动不等于空间释放。'}else{''}))
    Update-SjcGuiView $App
}
function Invoke-SjcGuiTick {
    param($App)
    $s=$App.State
    if($s.LocalJob){
        $job=$s.LocalJob
        if(-not $job.Handle.IsCompleted){return}
        try{
            $values=@($job.PowerShell.EndInvoke($job.Handle))
            if($job.PowerShell.HadErrors){throw ($job.PowerShell.Streams.Error|Out-String)}
            if($job.Cancel.IsCancellationRequested){throw '候选操作已取消。'}
            if($values.Count -eq 0){throw '后台候选操作没有返回结果。'}
            $result=$values[-1]
            switch($job.Kind){
                'Open' {$s.PageOffset=0;$s.PageItems=@($result.Items)}
                'Page' {Sync-SjcGuiPageSelection $App;$s.PageOffset=$job.Arguments.Offset;$s.PageItems=@($result.Items);$App.Ui.CandidatesList.SelectedItem=$null}
                'RuleKeep' {foreach($item in @($result.Items)){if($job.Arguments.Keep){$s.Excluded[$item.Id]=[int64]$item.Length;$s.ExcludedRule[$item.Id]=[string]$job.Arguments.RuleId}else{$s.Excluded.Remove($item.Id);$s.ExcludedRule.Remove($item.Id)}}}
                'Export' {Set-SjcGuiStatus $App ('完整导出 '+$result.ExportedCount+' 条候选至 '+$result.Destination)}
            }
            if($job.Kind -eq 'RuleKeep'){Set-SjcGuiStatus $App ($(if($job.Arguments.Keep){'已保留'}else{'已取消保留'})+'规则全部 '+@($result.Items).Count+' 个候选。')}
            elseif($job.Kind -notin @('Export','Close')){Set-SjcGuiStatus $App '候选操作完成。预览缓存不替代清理前校验。'}
        }catch{$s.PendingScan=$false;if($s.PendingApply){$s.PendingApply=$null;$s.DraftProfile=$s.Profile;Update-SjcGuiDraftAges $App};Set-SjcGuiStatus $App ('候选操作失败或已取消：'+$_.Exception.Message+$(if($job.Kind -eq 'Close'){'；档位未切换。'}else{''}))}
        finally{$job.PowerShell.Dispose();$job.Cancel.Dispose();$s.LocalJob=$null;$s.Busy=$false;Update-SjcGuiView $App}
        if($s.PendingApply){$pending=$s.PendingApply;$s.PendingApply=$null;try{Complete-SjcGuiProfileApply $App $pending.Profile $pending.SelectedIds}catch{$s.DraftProfile=$s.Profile;Update-SjcGuiDraftAges $App;Set-SjcGuiStatus $App ('档位切换失败，仍为'+(Get-SjcGuiProfileLabel $s.Profile)+'：'+$_.Exception.Message);Update-SjcGuiView $App}}
        if($s.PendingScan){$s.PendingScan=$false;Start-SjcGuiTask $App 'Scan'}
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
        'NavHome' {Set-SjcGuiPage $App 'Home'}
        'NavFiles' {Set-SjcGuiPage $App 'Files'}
        'NavRules' {Set-SjcGuiPage $App 'Rules'}
        'NavLogs' {Set-SjcGuiPage $App 'Logs'}
        'ViewFilesButton' {Set-SjcGuiPage $App 'Files'}
        'AdjustRulesButton' {Set-SjcGuiPage $App 'Rules'}
        'CancelButton' {Request-SjcGuiCancel $App}
        default {
            if($s.Busy){throw '请等待当前任务结束。'}
            switch($Command){
                'ScanButton' {if($s.Background -and $s.Background.Shared.Preview){$s.PendingScan=$true;Start-SjcGuiLocalJob $App 'Close' @{};Set-SjcGuiStatus $App '正在释放旧预览，然后开始新扫描。'}else{Start-SjcGuiTask $App 'Scan'}}
                'CleanButton' {
                    if(Test-SjcGuiCleanable $s){
                        Sync-SjcGuiPageSelection $App
                        $summary=Get-SjcGuiCleanSummary $s
                        if($summary.PendingCount -le 0){Set-SjcGuiStatus $App '所有候选都已保留，没有需要清理的文件。'}
                        elseif(Confirm-SjcGuiClean $App $summary){Start-SjcGuiTask $App 'Clean'}
                    }
                }
                'EmptyRecycleButton' {if(Confirm-SjcGui $App '永久清空当前可访问回收站，不能恢复。Windows 还会再次确认。是否继续？'){Start-SjcGuiTask $App 'Recycle'}}
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
                'ExportButton' {$dialog=[Microsoft.Win32.SaveFileDialog]::new();$dialog.Filter='CSV files (*.csv)|*.csv';$dialog.FileName='清理候选_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.csv';if($dialog.ShowDialog($u.Window)){Start-SjcGuiLocalJob $App 'Export' @{PlanPath=$s.Scan.PlanPath;Destination=$dialog.FileName;ExcludedIds=[string[]]@($s.Excluded.Keys)}}}
                'RecommendedButton' {foreach($row in $s.Draft){$row.Selected=$row.Recommended};Update-SjcGuiRuleHeaders $App -Refresh;Set-SjcGuiStatus $App '已在草稿中恢复推荐勾选；应用范围后生效。'}
                'SelectGroupButton' {$group=Get-SjcGuiCurrentGroup $App;if($group){Set-SjcGuiDraftGroup $App $group $true}}
                'ClearGroupButton' {$group=Get-SjcGuiCurrentGroup $App;if($group){Set-SjcGuiDraftGroup $App $group $false}}
                'ApplyRulesButton' {
                    $ids=[string[]]@($s.Draft|Where-Object Selected|ForEach-Object Id)
                    $target=Assert-SjcGuiProfileValue ([string]$s.DraftProfile)
                    if($target -cne $s.Profile){
                        if(-not $s.ProfileSupported){throw '当前引擎不支持切换档位。'}
                        if($s.Background -and $s.Background.Shared.Preview){$s.PendingApply=@{Profile=$target;SelectedIds=$ids};Start-SjcGuiLocalJob $App 'Close' @{};Set-SjcGuiStatus $App '正在释放旧预览，完成后切换档位。'}
                        else{Complete-SjcGuiProfileApply $App $target $ids}
                    }else{
                        $s.Selected.Clear();foreach($id in $ids){[void]$s.Selected.Add($id)}
                        $s.Stale=$true;$s.PageItems=@();Save-SjcGuiPreferences $App
                        Set-SjcGuiStatus $App ('范围已应用：'+$s.Selected.Count+' 条规则。旧扫描失效，需重新扫描。');Update-SjcGuiDraftText $App;Update-SjcGuiView $App
                    }
                }
                'CancelRulesButton' {Set-SjcGuiDraft $App;Set-SjcGuiStatus $App '已放弃规则草稿修改。'}
                'KeepRuleButton' {$current=$u.RulesList.SelectedItem;if($current -and $current.Kind -eq 'Rule' -and (Test-SjcGuiCleanable $s)){Start-SjcGuiLocalJob $App 'RuleKeep' @{RuleId=$current.Id;Keep=$true}}}
                'RestoreRuleButton' {$current=$u.RulesList.SelectedItem;if($current -and $current.Kind -eq 'Rule' -and (Test-SjcGuiCleanable $s)){Start-SjcGuiLocalJob $App 'RuleKeep' @{RuleId=$current.Id;Keep=$false}}}
                'OpenLogButton' {$selected=$u.HistoryList.SelectedItem;if($selected -and $selected.LogPath -and [IO.File]::Exists($selected.LogPath)){[void][Diagnostics.Process]::Start('notepad.exe',('"'+$selected.LogPath+'"'))}}
                'DetailsButton' {$selected=$u.HistoryList.SelectedItem;if($selected){Show-SjcGuiDetails $App ($selected.Result|ConvertTo-Json -Depth 10)}}
                'RemovePreviewButton' {$selected=$u.HistoryList.SelectedItem;if($selected -and $selected.TaskDirectory -ne $s.TaskDirectory -and (Confirm-SjcGui $App '仅移除选中已放弃任务的预览/通道记录，不删除目标文件和日志。继续？')){[void](Remove-SjcTaskDirectory $s.Context $selected.TaskDirectory);Set-SjcGuiStatus $App '已移除任务预览记录，日志仍保留。'}}
            }
        }
    }
}
function Remove-SjcGuiApp {
    param($App)
    if(-not $App -or $App.ResourcesClosed){return}
    $App.ResourcesClosed=$true
    if($App.Timer){$App.Timer.Stop()}
    if($App.State.LocalJob){$App.State.LocalJob.Cancel.Cancel();$App.State.LocalJob.PowerShell.Stop();$App.State.LocalJob.PowerShell.Dispose();$App.State.LocalJob.Cancel.Dispose()}
    if($App.State.Background){
        $background=$App.State.Background
        $power=[PowerShell]::Create();$power.Runspace=$background.Runspace
        try{[void]$power.AddScript('param($shared) if($shared.Preview){Close-SjcPreviewSession $shared.Preview;$shared.Preview=$null}').AddArgument($background.Shared);[void]$power.Invoke()}finally{$power.Dispose();$background.Runspace.Dispose()}
    }
}
function Start-SjcGui {
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw '请以 PowerShell -STA 启动。'}
    $context=New-SjcContext
    $warning='';$preferences=$null
    try{$preferences=Read-SjcPreferences $context}catch{$warning='设置读取失败，使用推荐范围：'+$_.Exception.Message}
    if($preferences -and (Get-SjcGuiValue $preferences 'CleaningProfile' 'Recommended') -ceq 'Deep' -and (Test-SjcGuiProfileSupport)){
        try{Set-SjcCleaningProfile -Context $context -CleaningProfile 'Deep'}catch{$warning='档位设置无法应用，使用推荐档：'+$_.Exception.Message}
    }
    $state=New-SjcGuiState $context
    if($preferences){$state.RecycleMode=$preferences.RecycleMode;$state.Selected.Clear();foreach($id in $preferences.SelectedRuleIds){if($state.RuleMap.ContainsKey($id)){[void]$state.Selected.Add($id)}}}
    $app=New-SjcGuiApp $state;$app.Ui.RecycleMode.IsChecked=$state.RecycleMode
    if($warning){Set-SjcGuiStatus $app $warning}
    try{[void]$app.Ui.Window.ShowDialog()}finally{Remove-SjcGuiApp $app}
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
function Set-SjcGuiTestLayout {
    param($App,[int]$Width,[int]$Height,[string]$Page)
    $App.Ui.Window.Width=$Width;$App.Ui.Window.Height=$Height;Set-SjcGuiPage $App $Page
    $visual=$App.Ui.Window.Content;$visual.Measure([Windows.Size]::new($Width,$Height));$visual.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$visual.UpdateLayout()
}
function Test-SjcGui {
    param([string]$PlanPath,[string]$ScreenshotDirectory)
    $passed=New-Object 'System.Collections.Generic.List[string]';$failed=New-Object 'System.Collections.Generic.List[string]';$skipped=New-Object 'System.Collections.Generic.List[string]';$app=$null;$session=$null;$confirm=$null
    try{
        Initialize-SjcDesktop
        $context=if($PlanPath){Get-SjcPlanContext ([IO.Path]::GetDirectoryName($PlanPath))}else{New-SjcTestSandbox|ForEach-Object Context}
        $s=New-SjcGuiState $context -TestMode;$app=New-SjcGuiApp $s
        foreach($name in @('Home','Files','Rules','Logs')){Set-SjcGuiPage $app $name;if($app.Ui[($name+'Page')].Visibility -ne 'Visible'){throw '导航页未显示: '+$name}}
        [void]$passed.Add('四页真实WPF控件导航')
        if((Get-SjcWorkbenchXaml).Contains('{G:') -or (Get-SjcWorkbenchXaml) -match 'Canvas|DropShadowEffect|LinearGradientBrush'){throw '图标映射未展开或仍有自绘装饰'}
        [void]$passed.Add('操作图标经集中映射展开，无自绘几何装饰')
        if(Get-SjcGuiIconPath){if(-not $app.Ui.Window.Icon -or -not $app.Ui.BrandIcon.Source){throw '应用图标未加载到窗口'};[void]$passed.Add('窗口与侧栏使用 assets\app.ico')}else{[void]$skipped.Add('未从源码入口运行，窗口图标路径未测')}
        $before=@($s.Selected);foreach($row in $s.Draft){$row.Selected=$false};Invoke-SjcGuiCommand $app 'CancelRulesButton'
        if(@($s.Draft|Where-Object Selected).Count -ne $before.Count){throw '规则草稿取消没有恢复'}
        [void]$passed.Add('规则草稿取消不改变已应用范围')
        $groups=@($s.Draft|ForEach-Object Group|Select-Object -Unique)
        if(@($s.RuleRows|Where-Object Kind -eq 'Header').Count -ne $groups.Count){throw '可见分组标题数量错误'}
        $app.Ui.RuleSearchBox.Text='__no_such_rule__'
        if($s.RuleRows.Count -ne 0 -or $app.Ui.RulesEmpty.Visibility -ne 'Visible'){throw '搜索无结果状态错误'}
        $app.Ui.RuleSearchBox.Text=''
        if(@($s.RuleRows|Where-Object Kind -eq 'Rule').Count -ne $s.Draft.Count){throw '清空搜索未恢复全部规则'}
        $app.Ui.RuleGroupFilter.SelectedIndex=1
        if(@($s.RuleRows|Where-Object{$_.Kind -eq 'Rule' -and $_.Group -ne $groups[0]}).Count){throw '分组过滤错误'}
        $app.Ui.RuleGroupFilter.SelectedIndex=0
        [void]$passed.Add('规则可见分组、搜索与分组过滤')
        if($s.Draft.Count -gt 1){
            $current=$s.Draft[-1];$app.Ui.RulesList.SelectedItem=$current
            Invoke-SjcGuiCommand $app 'SelectGroupButton'
            if(@($s.Draft|Where-Object{$_.Group -eq $current.Group -and -not $_.Selected}).Count){throw '当前组选取错误'}
            Invoke-SjcGuiCommand $app 'ClearGroupButton'
            if(@($s.Draft|Where-Object{$_.Group -eq $current.Group -and $_.Selected}).Count){throw '当前组清空错误'}
            Invoke-SjcGuiCommand $app 'CancelRulesButton'
            [void]$passed.Add('当前规则选择与启用独立，分组全选清空准确')
        }
        $s.ProfileSupported=$false;Update-SjcGuiView $app
        if($app.Ui.ProfileDeep.IsEnabled){throw '引擎未支持时深度档不应可选'}
        $s.ProfileSupported=$true;$s.DraftProfile='Deep';Update-SjcGuiView $app
        if(-not $app.Ui.ProfileDeep.IsEnabled -or $app.Ui.DraftText.Text -notmatch '档位'){throw '深度档草稿状态未显示'}
        if($s.Profile -ne 'Recommended' -or (Get-SjcGuiContextProfile $s.Context) -ne 'Recommended'){throw '草稿档位未经应用就改变了生效档位'}
        $s.ProfileSupported=(Test-SjcGuiProfileSupport)
        if($PlanPath){
            $s.DraftProfile=$s.Profile;Update-SjcGuiDraftAges $app;Update-SjcGuiView $app
            [void]$passed.Add('档位草稿：未接入时禁用深度，草稿不改变生效档位')
            [void]$skipped.Add('给定 PlanPath 时不真实切档，避免使该计划失效')
        }else{
            $keepIds=@($s.Selected)
            Invoke-SjcGuiCommand $app 'ApplyRulesButton'
            if($s.Profile -cne 'Deep' -or (Get-SjcGuiContextProfile $s.Context) -cne 'Deep' -or -not $s.Stale -or $null -ne $s.Scan){throw '应用深度档未切换引擎上下文或未要求重新扫描'}
            if(@($s.Selected|Where-Object{$keepIds -notcontains $_}).Count){throw '切档后自动扩选了规则'}
            $s.DraftProfile='Recommended';Invoke-SjcGuiCommand $app 'ApplyRulesButton'
            if($s.Profile -cne 'Recommended' -or (Get-SjcGuiContextProfile $s.Context) -cne 'Recommended'){throw '切回推荐档失败'}
            [void]$passed.Add('档位草稿：未接入时禁用深度，应用后真实切换引擎上下文并要求重扫')
        }
        $s.History.Add([pscustomobject]@{Time='01-01 12:00';Action='Scan';Status='完成';Summary='人工记录A';LogPath='';TaskDirectory='';Result=$null})
        $s.History.Add([pscustomobject]@{Time='01-01 12:01';Action='Clean';Status='已取消';Summary='人工记录B';LogPath='';TaskDirectory='';Result=$null})
        Update-SjcGuiView $app;$app.Ui.HistoryList.SelectedIndex=1;Update-SjcGuiView $app
        if($app.Ui.HistoryList.SelectedItem.Summary -ne '人工记录B'){throw '历史记录当前选择丢失'}
        [void]$passed.Add('历史记录保留当前选择而非默认第一条')
        $s.Busy=$true;Update-SjcGuiView $app
        if($app.Ui.ScanButton.IsEnabled -or $app.Ui.RecycleMode.IsEnabled -or $app.Ui.ApplyRulesButton.IsEnabled -or -not $app.Ui.CancelButton.IsEnabled){throw '运行中操作未冻结'}
        $s.Busy=$false;Update-SjcGuiView $app
        [void]$passed.Add('任务冻结与取消按钮状态')
        if($PlanPath){
            $session=Open-SjcPreviewSession $PlanPath;$items=@(Get-SjcPreviewPage $session -Limit 200)
            $s.Scan=[pscustomobject]@{Status='Success';CandidateCount=$session.Count;CandidateBytes=$session.Bytes;PlanPath=$PlanPath;Categories=@(@($s.Rules)|ForEach-Object{$rid=$_.Id;$list=@(if($session.ByRule.ContainsKey($rid)){$session.ByRule[$rid].ToArray()});[pscustomobject]@{RuleId=$rid;Name=$_.Name;Group=$_.Group;Risk=$_.Risk;Root=$_.Root;Count=[int64]$list.Count;Bytes=$(if($list.Count){[int64](($list|Measure-Object Length -Sum).Sum)}else{[int64]0});Status='Success';Note=$_.Note}})};$s.Stale=$false;$s.PageItems=$items;Update-SjcGuiView $app
            if($session.Count -gt 0 -and $app.Ui.CandidatesList.Items.Count -eq 0){throw '真实分页未进入候选控件'}
            if($items.Count){
                $first=$app.Ui.CandidatesList.Items[0]
                $check=[Windows.Controls.CheckBox]::new();$check.DataContext=$first;$check.IsChecked=$true
                Set-SjcGuiCandidateSelection $app $check
                if($s.Excluded.Count -ne 0 -or -not $app.Ui.SelectedPathText.Text.Contains($first.Path)){throw '选择与保留混淆或路径详情缺失'}
                Invoke-SjcGuiCommand $app 'KeepButton'
                if($app.Ui.MetricKept.Text -ne '1' -or -not $app.Ui.CandidatesList.Items[0].IsSelected){throw '保留项统计或选择保持错误'}
                Invoke-SjcGuiCommand $app 'RestoreButton'
                if($s.Excluded.Count -ne 0){throw '恢复选中没有移除保留项'}
                [void]$passed.Add('选中与保留独立、取消保留及完整路径详情')
                if($session.Count -gt 200){
                    Sync-SjcGuiPageSelection $app;$s.PageOffset=200;$s.PageItems=@(Get-SjcPreviewPage $session -Offset 200 -Limit 200);$app.Ui.CandidatesList.SelectedItem=$null;Update-SjcGuiView $app
                    $app.Ui.CandidatesList.Items[0].IsSelected=$true
                    Invoke-SjcGuiCommand $app 'KeepButton'
                    if($s.Excluded.Count -ne 2 -or $s.CandidateSelection.Count -ne 2 -or $app.Ui.SelectionSummaryText.Text -notmatch '其他页 1'){throw ('跨页勾选与保留不一致：'+$app.Ui.SelectionSummaryText.Text)}
                    $summary=Get-SjcGuiCleanSummary $s
                    if($summary.PendingCount -ne ($session.Count-2) -or $(if(@($summary.Rows).Count){(@($summary.Rows)|Measure-Object Count -Sum).Sum}else{0}) -ne $summary.PendingCount){throw '清理确认范围与未保留数量不符'}
                    $confirm=New-SjcGuiCleanConfirmWindow $app $summary
                    if($confirm.FindName('Headline').Text -notmatch ('{0:N0}' -f $summary.PendingCount) -or $confirm.FindName('CheckedText').Text -notmatch '不限定'){throw '清理确认未显示实际范围'}
                    [void]$passed.Add('跨页勾选保持、保留与详情一致；确认窗口显示全部未保留范围')
                    if($ScreenshotDirectory){[void][IO.Directory]::CreateDirectory($ScreenshotDirectory);$confirm.Width=880;$confirm.Height=560;Save-SjcGuiRender $confirm (Join-Path $ScreenshotDirectory 'Confirm.png')}
                }else{[void]$skipped.Add('计划不足 200 条，跨页未测')}
            }
            [void]$passed.Add('T17 真实封存计划分页与保留统计')
        }else{[void]$skipped.Add('未给PlanPath,真实分页未测')}
        foreach($size in @(@(1200,820),@(960,700))){
            foreach($page in @('Home','Files','Rules','Logs')){
                Set-SjcGuiTestLayout $app $size[0] $size[1] $page
                $bad=@(Get-SjcGuiTruncatedButtons $app)
                if($bad.Count){throw ('按钮文字被截断 {0} {1}x{2}: {3}' -f $page,$size[0],$size[1],($bad -join '; '))}
            }
            Set-SjcGuiTestLayout $app $size[0] $size[1] 'Home'
            if($app.Ui.ScanButton.ActualHeight -lt 30 -or $app.Ui.ScanButton.ActualWidth -lt 50){throw '主按钮未获得完整布局空间'}
            [void]$passed.Add(('主按钮布局与按钮无截断 {0}x{1}' -f $size[0],$size[1]))
        }
        if($app.Ui.CandidatesList.Items.Count){
            Set-SjcGuiTestLayout $app 1200 820 'Files'
            $container=$app.Ui.CandidatesList.ItemContainerGenerator.ContainerFromIndex(0)
            if(-not $container -or $container.ActualHeight -lt 30 -or $container.ActualHeight -gt 36){throw ('候选行高不在 30-36 DIP：'+$(if($container){$container.ActualHeight}else{'无容器'}))}
            $generated=0;for($i=0;$i -lt $app.Ui.CandidatesList.Items.Count;$i++){if($app.Ui.CandidatesList.ItemContainerGenerator.ContainerFromIndex($i)){$generated++}}
            if($generated -ge $app.Ui.CandidatesList.Items.Count -and $app.Ui.CandidatesList.Items.Count -gt 60){throw '候选表格未虚拟化'}
            [void]$passed.Add(('候选表格虚拟化，行高 {0} DIP，生成容器 {1}/{2}' -f $container.ActualHeight,$generated,$app.Ui.CandidatesList.Items.Count))
            foreach($size in @(@(1200,820),@(960,700))){
                Set-SjcGuiTestLayout $app $size[0] $size[1] 'Files';Resize-SjcGuiCandidateColumns $app.Ui.CandidatesList
                $total=0;foreach($column in $app.Ui.CandidatesList.View.Columns){$total+=$column.Width}
                if($total -gt $app.Ui.CandidatesList.ActualWidth-20){throw ('候选表格列在 {0}x{1} 溢出：{2:N0}/{3:N0}' -f $size[0],$size[1],$total,$app.Ui.CandidatesList.ActualWidth)}
            }
            [void]$passed.Add('候选表格六列在 1200x820 与 960x700 内完整显示')
        }
        if($ScreenshotDirectory){
            [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
            foreach($page in @('Home','Files','Rules','Logs')){Set-SjcGuiTestLayout $app 1200 820 $page;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory ($page+'.png'))}
            foreach($page in @('Home','Files','Rules')){Set-SjcGuiTestLayout $app 960 700 $page;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory ($page+'-960x700.png'))}
        }
        [void]$skipped.Add('真实显示器DPI/回收站系统确认需要非破坏性单独验收')
    }catch{[void]$failed.Add($_.Exception.Message+' @ '+$_.ScriptStackTrace)}
    finally{if($confirm){$confirm.Close()};if($session){Close-SjcPreviewSession $session};if($app){Remove-SjcGuiApp $app;$app.Ui.Window.Close()}}
    return [pscustomobject]@{Name='Test-SjcGui';Version=(Get-SjcVersion);Status=$(if($failed.Count){'Failed'}else{'Success'});Passed=[string[]]$passed.ToArray();Failed=[string[]]$failed.ToArray();Skipped=[string[]]$skipped.ToArray()}
}
