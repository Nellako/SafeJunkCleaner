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
function Get-SjcWorkbenchXaml {
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="星梦雨垃圾清理器 v__PRODUCT_VERSION__" Width="1200" Height="820" MinWidth="960" MinHeight="700" WindowStartupLocation="CenterScreen" Background="#F3F6FB" FontFamily="Microsoft YaHei UI" FontSize="14" Foreground="#16213A" UseLayoutRounding="True">
 <Window.Resources>
  <SolidColorBrush x:Key="Blue" Color="#2F6BFF"/>
  <SolidColorBrush x:Key="BlueSoft" Color="#EAF1FF"/>
  <SolidColorBrush x:Key="BlueInk" Color="#1C3F9E"/>
  <SolidColorBrush x:Key="Line" Color="#E6EBF3"/>
  <Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style>
  <Style x:Key="Muted" TargetType="TextBlock"><Setter Property="Foreground" Value="#6B7890"/><Setter Property="FontSize" Value="12"/></Style>
  <Style x:Key="Title" TargetType="TextBlock"><Setter Property="FontSize" Value="24"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="12"/><Setter Property="Padding" Value="18"/><Setter Property="Margin" Value="0,0,0,16"/><Setter Property="BorderBrush" Value="#E6EBF3"/><Setter Property="BorderThickness" Value="1"/></Style>
  <Style TargetType="Button"><Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="BorderBrush" Value="#D5DEEB"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="14,8"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Cursor" Value="Hand"/><Setter Property="HorizontalContentAlignment" Value="Center"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/></Border></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F7F9FD"/><Setter Property="Foreground" Value="#16213A"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#EEF1F6"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger></Style.Triggers></Style>
  <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="BorderThickness" Value="0"/><Setter Property="Foreground" Value="White"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="10" Padding="{TemplateBinding Padding}"><Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="6" Color="#2F6BFF" Opacity="0.32"/></Border.Effect><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/></Border></ControlTemplate></Setter.Value></Setter><Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#4F8DFF" Offset="0"/><GradientStop Color="#2F6BFF" Offset="0.55"/><GradientStop Color="#1D4FE0" Offset="1"/></LinearGradientBrush></Setter.Value></Setter><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.92"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger></Style.Triggers></Style>
  <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="16,12"/><Setter Property="Margin" Value="0,3"/></Style>
  <Style TargetType="ListBoxItem"><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Padding" Value="0"/><Setter Property="Margin" Value="0,0,0,10"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="SelectionBorder" CornerRadius="12" BorderThickness="2" BorderBrush="Transparent"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="SelectionBorder" Property="BorderBrush" Value="#7BA5FF"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="SelectionBorder" Property="BorderBrush" Value="#2F6BFF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#3D4A63"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/></Style>
 </Window.Resources>
 <Grid Background="#F3F6FB">
  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
   <DockPanel Margin="12,20,12,16">
    <StackPanel DockPanel.Dock="Top" Margin="6,0,0,22"><Border Width="36" Height="36" CornerRadius="10" Margin="0,0,0,10"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#4FA8FF" Offset="0"/><GradientStop Color="#2F6BFF" Offset="0.6"/><GradientStop Color="#1D4FE0" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="4" Color="#2F6BFF" Opacity="0.35"/></Border.Effect><TextBlock Text="&#xE71B;" FontFamily="Segoe MDL2 Assets" Foreground="White" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><TextBlock Text="星梦雨垃圾清理器" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="安全清理工作台" Style="{StaticResource Muted}" FontSize="12" Margin="0,2,0,0"/></StackPanel>
    <Border DockPanel.Dock="Bottom" Background="{StaticResource BlueSoft}" CornerRadius="10" Padding="12"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xEA18;" FontFamily="Segoe MDL2 Assets" Foreground="#6B7890" FontSize="11" Margin="0,0,6,0"/><TextBlock Text="仅处理已核实的缓存与临时文件。不提权，不结束应用。" Style="{StaticResource Muted}" Width="135"/></StackPanel></Border>
    <StackPanel><TextBlock Text="工作区" Style="{StaticResource Muted}" Margin="10,0,0,6"/><Button x:Name="NavHome" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBlock Text="工作台"/></StackPanel></Button><Button x:Name="NavFiles" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8A5;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBlock Text="候选文件"/></StackPanel></Button><Button x:Name="NavRules" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73A;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBlock Text="清理规则"/></StackPanel></Button><Button x:Name="NavLogs" Style="{StaticResource NavButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE823;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBlock Text="任务记录"/></StackPanel></Button></StackPanel>
   </DockPanel>
  </Border>
  <Grid Grid.Column="1">
   <Grid.RowDefinitions><RowDefinition Height="56"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Border Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="22,0"><DockPanel VerticalAlignment="Center"><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Border Background="{StaticResource BlueSoft}" CornerRadius="9" Padding="10,5"><TextBlock Text="v__PRODUCT_VERSION__" Foreground="{StaticResource BlueInk}" FontSize="12" FontWeight="Medium"/></Border></StackPanel><TextBlock x:Name="Breadcrumb" Text="星梦雨垃圾清理器  /  工作台" Foreground="#6B7890" FontSize="13"/></DockPanel></Border>
   <Grid Grid.Row="1" Margin="22,18,22,0">
    <ScrollViewer x:Name="HomePage" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
     <StackPanel MaxWidth="1100">
      <TextBlock Text="清理工作台" Style="{StaticResource Title}"/><TextBlock Text="找回空间,让每次清理都心中有数。" Style="{StaticResource Muted}" Margin="0,6,0,16"/>
      <Border CornerRadius="16" Padding="26,24" Margin="0,0,0,18"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#EEF4FF" Offset="0"/><GradientStop Color="#E3EDFF" Offset="0.5"/><GradientStop Color="#D6E6FF" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect BlurRadius="0" ShadowDepth="0" Color="Transparent"/></Border.Effect>
       <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*" MinWidth="380"/><ColumnDefinition Width="190"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="检查可以安全整理的空间" FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource BlueInk}"/><TextBlock Text="扫描只生成预览,不删除文件。&#10;默认移入回收站,执行前确认。" Foreground="#3D4A63" Margin="0,6,0,14" FontSize="13"/><WrapPanel><Button x:Name="ScanButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE71E;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="开始扫描"/></StackPanel></Button><Button x:Name="ViewFilesButton" Margin="8,0,0,0"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8A5;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="查看候选"/></StackPanel></Button><Button x:Name="CancelButton" Visibility="Collapsed" Foreground="#C2342B" BorderBrush="#F1C7C3" Margin="8,0,0,0"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="取消任务"/></StackPanel></Button></WrapPanel><TextBlock x:Name="ScopeText" Style="{StaticResource Muted}" Margin="0,12,0,0"/></StackPanel>
       <Grid Grid.Column="1" IsHitTestVisible="False" Margin="0,-10,0,0"><Canvas Width="170" Height="150"><Ellipse Fill="#C9DCFF" Width="90" Height="90" Canvas.Left="42" Canvas.Top="-10" Opacity="0.4"/><Border Width="150" Height="96" CornerRadius="14" Canvas.Left="10" Canvas.Bottom="18"><Border.Background><LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1"><GradientStop Color="#7FB3FF" Offset="0"/><GradientStop Color="#3B78FF" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="18" Color="#2F6BFF" Opacity="0.28"/></Border.Effect></Border><Border Width="58" Height="22" CornerRadius="9,9,0,0" Background="#6AA3FF" Canvas.Left="22" Canvas.Bottom="100"/><Border Width="104" Height="70" CornerRadius="10" Background="#D9FFFFFF" Canvas.Left="34" Canvas.Bottom="62" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><RotateTransform Angle="-6"/></Border.RenderTransform><Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="6" Color="#244080" Opacity="0.12"/></Border.Effect><StackPanel Margin="14,16,22,0"><Border Height="6" Background="#CFDCF5" CornerRadius="3"/><Border Height="6" Background="#DFE8F8" CornerRadius="3" Margin="0,14,0,0"/><Border Height="6" Background="#DFE8F8" CornerRadius="3" Margin="0,14,0,0"/></StackPanel></Border><Border Width="170" Height="70" CornerRadius="14" Canvas.Right="30" Canvas.Bottom="12" Opacity="0.9"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#BFFFFFFF" Offset="0"/><GradientStop Color="#99D6E6FF" Offset="1"/></LinearGradientBrush></Border.Background><Border BorderBrush="#CCFFFFFF" BorderThickness="1" CornerRadius="14"/></Border><Border Width="58" Height="58" CornerRadius="16" Canvas.Right="10" Canvas.Bottom="40" RenderTransformOrigin="0.5,0.5"><Border.RenderTransform><RotateTransform Angle="8"/></Border.RenderTransform><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#34D399" Offset="0"/><GradientStop Color="#14935A" Offset="1"/></LinearGradientBrush></Border.Background><Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="10" Color="#14935A" Opacity="0.3"/></Border.Effect><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="White" FontSize="28" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></Canvas></Grid></Grid>
      </Border>
      <UniformGrid Columns="3" Margin="0,0,-14,0"><Border Style="{StaticResource Card}" Margin="0,0,14,16"><StackPanel><Grid Margin="0,0,0,8"><Border Width="40" Height="40" CornerRadius="11" Background="{StaticResource BlueSoft}" HorizontalAlignment="Left"><TextBlock Text="&#xEDA2;" FontFamily="Segoe MDL2 Assets" Foreground="{StaticResource Blue}" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></Grid><TextBlock Text="候选逻辑大小" Style="{StaticResource Muted}"/><TextBlock x:Name="MetricBytes" Text="—" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,4"/><TextBlock Text="扫描预估,不等于实际释放" Style="{StaticResource Muted}"/></StackPanel></Border><Border Style="{StaticResource Card}" Margin="0,0,14,16"><StackPanel><Grid Margin="0,0,0,8"><Border Width="40" Height="40" CornerRadius="11" Background="#E7F6EE" HorizontalAlignment="Left"><TextBlock Text="&#xE7C3;" FontFamily="Segoe MDL2 Assets" Foreground="#14935A" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></Grid><TextBlock Text="候选文件" Style="{StaticResource Muted}"/><TextBlock x:Name="MetricCount" Text="—" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,4"/><TextBlock x:Name="PendingText" Text="尚未扫描" Style="{StaticResource Muted}"/></StackPanel></Border><Border Style="{StaticResource Card}" Margin="0,0,14,16"><StackPanel><Grid Margin="0,0,0,8"><Border Width="40" Height="40" CornerRadius="11" Background="#FFF4E5" HorizontalAlignment="Left"><TextBlock Text="&#xE735;" FontFamily="Segoe MDL2 Assets" Foreground="#B4630A" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></Grid><TextBlock Text="保留项(不处理)" Style="{StaticResource Muted}"/><TextBlock x:Name="MetricKept" Text="—" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,4"/><TextBlock Text="保留只会减少处理范围" Style="{StaticResource Muted}"/></StackPanel></Border></UniformGrid>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/><ColumnDefinition Width="290"/></Grid.ColumnDefinitions>
       <Border Style="{StaticResource Card}"><StackPanel><DockPanel Margin="0,0,0,14"><Button x:Name="AdjustRulesButton" DockPanel.Dock="Right" Padding="10,6" BorderThickness="0" Background="Transparent" Foreground="{StaticResource Blue}" FontWeight="Normal" Margin="0"><StackPanel Orientation="Horizontal"><TextBlock Text="调整范围"/><TextBlock Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Margin="4,0,0,0"/></StackPanel></Button><TextBlock Text="分类清理" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/></DockPanel><ItemsControl x:Name="CategoryList"><ItemsControl.ItemTemplate><DataTemplate><Border Padding="0,12" BorderBrush="#EEF1F6" BorderThickness="0,0,0,1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="{Binding Name}" FontWeight="Medium" FontSize="14"/><TextBlock Text="{Binding StatusText}" Foreground="#6B7890" Margin="0,6,0,0"/></StackPanel><StackPanel Grid.Column="1" HorizontalAlignment="Right"><TextBlock Text="{Binding SizeText}" HorizontalAlignment="Right" FontWeight="Medium" FontSize="14"/><TextBlock Text="{Binding CountText}" Foreground="#6B7890" HorizontalAlignment="Right" Margin="0,6,0,0"/></StackPanel></Grid></Border></DataTemplate></ItemsControl.ItemTemplate></ItemsControl></StackPanel></Border>
       <Border Grid.Column="2" Style="{StaticResource Card}"><StackPanel><TextBlock Text="安全策略" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/><StackPanel><StackPanel Orientation="Horizontal" Margin="0,0,0,10"><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#14935A" Margin="0,0,8,0"/><TextBlock Text="只处理已批准的精确目录" Foreground="#3D4A63" FontSize="13"/></StackPanel><StackPanel Orientation="Horizontal" Margin="0,0,0,10"><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#14935A" Margin="0,0,8,0"/><TextBlock Text="清理前复核路径与文件身份" Foreground="#3D4A63" FontSize="13"/></StackPanel><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#14935A" Margin="0,0,8,0"/><TextBlock Text="文件变化或只读时跳过" Foreground="#3D4A63" FontSize="13"/></StackPanel></StackPanel><Border Height="1" Background="{StaticResource Line}" Margin="0,14,0,10"/><CheckBox x:Name="RecycleMode" Content="移入回收站(推荐)" IsChecked="True" FontWeight="Medium"/><TextBlock Text="移入回收站通常不会立即释放空间。" Style="{StaticResource Muted}" Margin="0,4,0,12"/><Button x:Name="EmptyRecycleButton" Foreground="#C2342B" BorderBrush="#F1C7C3" Margin="0"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Margin="0,0,6,0"/><TextBlock Text="清空回收站…"/></StackPanel></Button></StackPanel></Border>
      </Grid>
      <Border Style="{StaticResource Card}"><StackPanel><TextBlock Text="最近任务" FontSize="16" FontWeight="SemiBold"/><TextBlock x:Name="LastTaskText" Text="尚无任务。扫描完成后,可查看候选再决定处理。" Style="{StaticResource Muted}" Margin="0,10,0,0"/></StackPanel></Border>
     </StackPanel>
    </ScrollViewer>
    <Grid x:Name="FilesPage" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <StackPanel Margin="0,0,0,14"><TextBlock Text="候选文件" Style="{StaticResource Title}"/><TextBlock Text="完整候选分页查看。选中后可保留、恢复或复制路径。" Style="{StaticResource Muted}" Margin="0,6,0,12"/><WrapPanel><Button x:Name="KeepButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE735;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="保留选中"/></StackPanel></Button><Button x:Name="RestoreButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="恢复选中"/></StackPanel></Button><Button x:Name="CopyPathButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="复制路径"/></StackPanel></Button><Button x:Name="ExportButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="完整导出 CSV"/></StackPanel></Button><Button x:Name="CleanButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE71B;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="清理候选…"/></StackPanel></Button></WrapPanel></StackPanel>
     <Border Grid.Row="1" Background="{StaticResource BlueSoft}" Padding="14" CornerRadius="10" Margin="0,0,0,12"><TextBlock x:Name="FileSummary" Text="先扫描生成候选。" Foreground="{StaticResource BlueInk}" FontWeight="Medium"/></Border>
     <Border Grid.Row="2" Style="{StaticResource Card}" Padding="0" Margin="0,0,0,12"><Grid><ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsControl x:Name="CandidatesList"><ItemsControl.ItemTemplate><DataTemplate><Border Padding="16,12" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Background="White"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*" MinWidth="200"/><ColumnDefinition Width="140"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions><CheckBox AutomationProperties.Name="{Binding Path}" IsChecked="{Binding IsSelected,Mode=TwoWay}" VerticalAlignment="Top" Margin="0,4,0,0"/><StackPanel Grid.Column="1" Margin="4,0,12,0"><TextBlock Text="{Binding Path}" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12" TextWrapping="Wrap" Foreground="#6B7890"/></StackPanel><TextBlock Grid.Column="2" Text="{Binding RuleName}" VerticalAlignment="Top" Foreground="#3D4A63" Margin="0,4,0,0"/><StackPanel Grid.Column="3" HorizontalAlignment="Right"><TextBlock Text="{Binding StateText}" FontWeight="Medium" HorizontalAlignment="Right" Margin="0,4,0,4"><TextBlock.Style><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#14935A"/><Style.Triggers><DataTrigger Binding="{Binding StateText}" Value="待处理"><Setter Property="Foreground" Value="#3D4A63"/></DataTrigger></Style.Triggers></Style></TextBlock.Style></TextBlock><TextBlock Text="{Binding SizeText}" Foreground="#6B7890" HorizontalAlignment="Right"/></StackPanel></Grid></Border></DataTemplate></ItemsControl.ItemTemplate></ItemsControl></ScrollViewer><Border x:Name="CandidatesEmpty" Background="#F7F9FD" CornerRadius="12" Padding="40,60" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"><StackPanel HorizontalAlignment="Center"><TextBlock Text="&#xE8A5;" FontFamily="Segoe MDL2 Assets" FontSize="48" Foreground="#D5DEEB" HorizontalAlignment="Center" Margin="0,0,0,18"/><TextBlock Text="尚无候选文件" FontSize="16" FontWeight="Medium" Foreground="#6B7890" HorizontalAlignment="Center"/><TextBlock Text="先在工作台扫描生成候选。" Style="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,6,0,0"/></StackPanel></Border></Grid></Border>
     <WrapPanel Grid.Row="3" Margin="0,0,0,10" VerticalAlignment="Center"><Button x:Name="PreviousButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE76B;" FontFamily="Segoe MDL2 Assets" Margin="0,0,6,0"/><TextBlock Text="上一页"/></StackPanel></Button><Button x:Name="NextButton"><StackPanel Orientation="Horizontal"><TextBlock Text="下一页"/><TextBlock Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" Margin="6,0,0,0"/></StackPanel></Button><TextBlock x:Name="PageText" VerticalAlignment="Center" Margin="10,0" Foreground="#6B7890"/></WrapPanel>
     <Border Grid.Row="4" Background="#F7F9FD" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,14"><DockPanel><TextBlock DockPanel.Dock="Top" Text="选中文件完整路径" Style="{StaticResource Muted}" Margin="0,0,0,6"/><TextBox x:Name="SelectedPathText" MaxHeight="70" VerticalScrollBarVisibility="Auto" IsReadOnly="True" BorderThickness="0" Background="Transparent" TextWrapping="Wrap" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" FontSize="12" Foreground="#3D4A63" Text="选中一个文件后显示完整路径"/></DockPanel></Border>
    </Grid>
    <Grid x:Name="RulesPage" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><StackPanel Margin="0,0,0,14"><TextBlock Text="清理规则" Style="{StaticResource Title}"/><TextBlock Text="修改采用草稿,应用后生效;不会添加任意清理路径。" Style="{StaticResource Muted}" Margin="0,6,0,12"/><WrapPanel><Button x:Name="RecommendedButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="恢复推荐范围"/></StackPanel></Button><Button x:Name="SelectGroupButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73A;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="全选当前分组"/></StackPanel></Button><Button x:Name="ClearGroupButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="清空当前分组"/></StackPanel></Button></WrapPanel></StackPanel>
     <ListBox Grid.Row="1" x:Name="RulesList" Margin="0,0,0,14" BorderThickness="0" Background="Transparent" ScrollViewer.HorizontalScrollBarVisibility="Disabled"><ListBox.ItemTemplate><DataTemplate><Border Style="{StaticResource Card}" Margin="0,0,0,12"><DockPanel><CheckBox IsChecked="{Binding Selected,Mode=TwoWay}" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,2,14,0"/><StackPanel><Grid Margin="0,0,0,6"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="{Binding Name}" FontWeight="Medium" FontSize="14"/><StackPanel Grid.Column="1" Orientation="Horizontal"><Border Background="{StaticResource BlueSoft}" CornerRadius="6" Padding="7,3" Margin="0,0,6,0" Visibility="{Binding RecommendedVisibility}"><TextBlock Text="推荐" Foreground="{StaticResource BlueInk}" FontSize="11"/></Border><Border Background="#F7F9FD" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="7,3"><TextBlock Foreground="#6B7890" FontSize="11"><Run Text="{Binding Group}"/>  ·  <Run Text="{Binding AgeText}"/></TextBlock></Border></StackPanel></Grid><TextBlock Text="{Binding AvailableText}" Foreground="#6B7890" FontSize="12"/><TextBlock Text="{Binding RiskText}" Foreground="#6B7890" FontSize="12" Margin="0,5,0,0"/><TextBlock Text="{Binding Note}" Foreground="#6B7890" FontSize="12" Margin="0,5,0,0"/><TextBlock Text="{Binding Root}" Foreground="#7A88A0" FontSize="11" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" ToolTip="{Binding Root}" Margin="0,5,0,0"/></StackPanel></DockPanel></Border></DataTemplate></ListBox.ItemTemplate></ListBox>
     <WrapPanel Grid.Row="2" Margin="0,0,0,14"><Button x:Name="ApplyRulesButton" Style="{StaticResource PrimaryButton}"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="应用范围"/></StackPanel></Button><Button x:Name="CancelRulesButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="放弃修改"/></StackPanel></Button><Button x:Name="KeepRuleButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE735;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="保留此规则全部候选"/></StackPanel></Button><Button x:Name="RestoreRuleButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="恢复此规则候选"/></StackPanel></Button></WrapPanel></Grid>
    <Grid x:Name="LogsPage" Visibility="Collapsed"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><StackPanel Margin="0,0,0,14"><TextBlock Text="任务记录" Style="{StaticResource Title}"/><TextBlock Text="本次会话记录;日志保存在本地私有目录,可能包含完整路径。" Style="{StaticResource Muted}" Margin="0,6,0,0"/></StackPanel>
     <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><Grid><ListBox x:Name="HistoryList" Margin="0,0,0,14" BorderThickness="0" Background="Transparent"><ListBox.ItemContainerStyle><Style TargetType="ListBoxItem"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="border" Background="White" CornerRadius="12" Padding="16" Margin="0,0,0,10" BorderBrush="#E6EBF3" BorderThickness="1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="{Binding Time}" Foreground="#6B7890" FontFamily="Cascadia Mono,Consolas,Microsoft YaHei UI" VerticalAlignment="Top"/><StackPanel Grid.Column="1" Margin="10,0"><Border Background="#F7F9FD" CornerRadius="6" Padding="7,4"><TextBlock Text="{Binding Action}" Foreground="#3D4A63" FontSize="12" HorizontalAlignment="Center"/></Border></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="{Binding Status}" FontWeight="Medium" Margin="0,0,0,4"/><TextBlock Text="{Binding Summary}" Foreground="#6B7890" TextWrapping="Wrap"/></StackPanel></Grid></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="{StaticResource Blue}"/><Setter TargetName="border" Property="BorderThickness" Value="2"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="#D5DEEB"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></ListBox.ItemContainerStyle></ListBox><Border x:Name="HistoryEmpty" Background="#F7F9FD" CornerRadius="12" Padding="40,60" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"><StackPanel HorizontalAlignment="Center"><TextBlock Text="&#xE823;" FontFamily="Segoe MDL2 Assets" FontSize="48" Foreground="#D5DEEB" HorizontalAlignment="Center" Margin="0,0,0,18"/><TextBlock Text="尚无任务记录" FontSize="16" FontWeight="Medium" Foreground="#6B7890" HorizontalAlignment="Center"/><TextBlock Text="扫描完成后,任务会在这里显示。" Style="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,6,0,0"/></StackPanel></Border></Grid></ScrollViewer>
     <WrapPanel Grid.Row="2" Margin="0,0,0,14"><Button x:Name="OpenLogButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="打开选中日志"/></StackPanel></Button><Button x:Name="DetailsButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="查看任务详情"/></StackPanel></Button><Button x:Name="RemovePreviewButton"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,6,0"/><TextBlock Text="删除已放弃的预览记录"/></StackPanel></Button></WrapPanel></Grid>
   </Grid>
   <Border Grid.Row="2" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="20,12"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="StatusText" Text="就绪。先扫描预览,不自动删除文件。" Foreground="#6B7890" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/><ProgressBar x:Name="BusyProgress" Grid.Column="1" Width="110" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="12,0,0,0"/></Grid></Border>
  </Grid>
 </Grid>
</Window>
'@
    return $xaml.Replace('__PRODUCT_VERSION__',(Get-SjcVersion))
}
function New-SjcGuiState {
    param($Context,[switch]$TestMode)
    $rules=@(Get-SjcRules $Context)
    $selected=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($rule in $rules){if($rule.Recommended){[void]$selected.Add($rule.Id)}}
    return @{Context=$Context;Rules=$rules;Selected=$selected;RecycleMode=$true;Scan=$null;TaskDirectory='';Stale=$true;Excluded=@{};CandidateSelection=@{};PageOffset=0;PageSize=200;PageItems=@();History=(New-Object 'System.Collections.Generic.List[object]');Task=$null;LocalJob=$null;Background=$null;Page='Home';TestMode=[bool]$TestMode;Busy=$false;Status='就绪。先扫描预览，不自动删除文件。';LastResult=$null;Draft=@();Closing=$false;PendingScan=$false}
}
function New-SjcGuiApp {
    param([Parameter(Mandatory=$true)]$State)
    Initialize-SjcDesktop
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new((Get-SjcWorkbenchXaml)))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    $ui=@{Window=$window}
    foreach($match in [regex]::Matches((Get-SjcWorkbenchXaml),'x:Name="([A-Za-z0-9]+)"')){$name=$match.Groups[1].Value;$ui[$name]=$window.FindName($name)}
    $app=@{State=$State;Ui=$ui;Timer=$null;ResourcesClosed=$false}
    $window.Tag=$app
    foreach($name in @('NavHome','NavFiles','NavRules','NavLogs','ScanButton','ViewFilesButton','CancelButton','AdjustRulesButton','EmptyRecycleButton','KeepButton','RestoreButton','CopyPathButton','ExportButton','CleanButton','PreviousButton','NextButton','RecommendedButton','SelectGroupButton','ClearGroupButton','ApplyRulesButton','CancelRulesButton','KeepRuleButton','RestoreRuleButton','OpenLogButton','DetailsButton','RemovePreviewButton')){
        $ui[$name].Tag=@{App=$app;Name=$name}
        $accessible=@{NavHome='工作台';NavFiles='候选文件';NavRules='清理规则';NavLogs='任务记录';ScanButton='开始扫描';ViewFilesButton='查看候选';CancelButton='取消任务';KeepButton='保留选中';RestoreButton='恢复选中';NextButton='下一页';PreviousButton='上一页';ApplyRulesButton='应用范围';CancelRulesButton='放弃修改'}
        [Windows.Automation.AutomationProperties]::SetName($ui[$name],$(if($accessible.ContainsKey($name)){$accessible[$name]}else{$name}))
        $ui[$name].Add_Click({param($sender,$event) try{Invoke-SjcGuiCommand $sender.Tag.App $sender.Tag.Name}catch{Set-SjcGuiStatus $sender.Tag.App ('操作失败: '+$_.Exception.Message)}})
    }
    $ui.RecycleMode.Tag=$app
    $ui.RecycleMode.Add_Click({param($sender,$event) $app=$sender.Tag;if(-not $app.State.Busy){$app.State.RecycleMode=[bool]$sender.IsChecked;Save-SjcGuiPreferences $app;Update-SjcGuiView $app}})
    $ui.CandidatesList.Tag=$app
    $ui.CandidatesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiCandidateSelection $sender.Tag $event.OriginalSource})
    $ui.CandidatesList.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,[Windows.RoutedEventHandler]{param($sender,$event) Set-SjcGuiCandidateSelection $sender.Tag $event.OriginalSource})
    $ui.RulesList.Tag=$app
    $ui.RulesList.Add_SelectionChanged({param($sender,$event) $row=$sender.SelectedItem;if($row){Set-SjcGuiStatus $sender.Tag ('当前规则：'+$row.Name+' · '+$row.Group+'。启用复选框与当前选择相互独立。')}})
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
    }
    $label=@{Home='工作台';Files='候选文件';Rules='清理规则';Logs='任务记录'}[$Page]
    $App.Ui.Breadcrumb.Text='星梦雨垃圾清理器  /  '+$label
}
function Set-SjcGuiDraft {
    param($App)
    $App.State.Draft=@($App.State.Rules|ForEach-Object{
        [pscustomobject]@{
            Id=$_.Id
            Selected=$App.State.Selected.Contains($_.Id)
            Name=$_.Name
            Root=$_.Root
            Note=$_.Note
            RiskText=("风险："+$_.Risk)
            Group=$_.Group
            AgeText=([string]$_.MinimumAgeHours+' 小时')
            AvailableText=$(if($_.Available){'目录存在'}else{'目录不存在,扫描时跳过'})
            Recommended=$_.Recommended
            RecommendedVisibility=$(if($_.Recommended){'Visible'}else{'Collapsed'})
        }
    })
    $App.Ui.RulesList.ItemsSource=$App.State.Draft
}
function Save-SjcGuiPreferences {
    param($App)
    if($App.State.TestMode){return}
    try{[void](Save-SjcPreferences -Context $App.State.Context -Preferences ([pscustomobject]@{RecycleMode=[bool]$App.State.RecycleMode;SelectedRuleIds=[string[]]@($App.State.Selected)}))}
    catch{Set-SjcGuiStatus $App ('设置未能保存，本次会话仍可使用：'+$_.Exception.Message)}
}
function Test-SjcGuiCleanable {
    param($State)
    return ($null -ne $State.Scan -and -not $State.Stale -and $State.Scan.Status -in @('Success','Partial') -and $State.Scan.CandidateCount -gt 0)
}
function Set-SjcGuiCandidateSelection {
    param($App,$CheckBox)
    if($null -eq $CheckBox -or $CheckBox -isnot [Windows.Controls.CheckBox]){return}
    $row=$CheckBox.DataContext
    if($null -eq $row -or -not $row.PSObject.Properties['Id']){return}
    $row.IsSelected=[bool]$CheckBox.IsChecked
    if($row.IsSelected){$App.State.CandidateSelection[$row.Id]=$row.Path}else{$App.State.CandidateSelection.Remove($row.Id)}
    $App.Ui.SelectedPathText.Text=if($App.State.CandidateSelection.Count){[string[]]@($App.State.CandidateSelection.Values)-join "`r`n"}else{'选中一个文件后显示完整路径'}
}
function Update-SjcGuiView {
    param($App)
    $s=$App.State;$u=$App.Ui;$idle=-not $s.Busy;$cleanable=Test-SjcGuiCleanable $s
    $u.ScopeText.Text=('已选 {0} / {1} 条规则  ·  {2}' -f $s.Selected.Count,$s.Rules.Count,$(if($s.RecycleMode){'移入回收站'}else{'永久删除'}))
    foreach($name in @('ScanButton','AdjustRulesButton','RecycleMode','EmptyRecycleButton','ApplyRulesButton','RecommendedButton','SelectGroupButton','ClearGroupButton','CancelRulesButton','RulesList','RemovePreviewButton')){$u[$name].IsEnabled=$idle}
    $u.ScanButton.IsEnabled=$idle -and $s.Selected.Count -gt 0
    foreach($name in @('KeepButton','RestoreButton','KeepRuleButton','RestoreRuleButton','CleanButton','ExportButton')){$u[$name].IsEnabled=$idle -and $cleanable}
    $u.CancelButton.Visibility=if($s.Busy){'Visible'}else{'Collapsed'}
    $u.CancelButton.IsEnabled=$s.Busy
    $u.BusyProgress.Visibility=if($s.Busy){'Visible'}else{'Collapsed'}
    $u.PreviousButton.IsEnabled=$idle -and $null -ne $s.Scan -and $s.PageOffset -gt 0
    $u.NextButton.IsEnabled=$idle -and $null -ne $s.Scan -and ($s.PageOffset+$s.PageSize) -lt $s.Scan.CandidateCount
    if($s.Scan -and -not $s.Stale){
        $u.MetricBytes.Text=Format-SjcGuiSize $s.Scan.CandidateBytes;$u.MetricCount.Text=('{0:N0}' -f $s.Scan.CandidateCount);$u.MetricKept.Text=[string]$s.Excluded.Count
        $u.PendingText.Text=('本次将处理 {0:N0} 个' -f ($s.Scan.CandidateCount-$s.Excluded.Count))
        $u.FileSummary.Text=('候选 {0:N0} 个  ·  已保留 {1:N0} 个  ·  模式: {2}' -f $s.Scan.CandidateCount,$s.Excluded.Count,$(if($s.RecycleMode){'移入回收站(不等于释放空间)'}else{'永久删除'}))
        $u.PageText.Text=('{0} / {1} 页  ·  每页 {2} 条' -f ([math]::Floor($s.PageOffset/$s.PageSize)+1),[math]::Max(1,[math]::Ceiling($s.Scan.CandidateCount/$s.PageSize)),$s.PageSize)
    }else{
        foreach($name in @('MetricBytes','MetricCount','MetricKept')){$u[$name].Text='—'}
        $u.PendingText.Text=if($s.Scan){'需重新扫描'}else{'尚未扫描'}
        $u.FileSummary.Text=if($s.Scan){'旧扫描快照已失效,需重新扫描。'}else{'先扫描生成候选。'};$u.PageText.Text=''
    }
    $rows=@($s.PageItems|ForEach-Object{
        $item=$_;$rule=@($s.Rules|Where-Object Id -eq $item.RuleId|Select-Object -First 1)
        $isKept=$s.Excluded.ContainsKey($item.Id)
        [pscustomobject]@{
            Id=$item.Id
            Path=$item.Path
            RuleId=$item.RuleId
            RuleName=$(if($rule.Count){$rule[0].Name}else{$item.RuleId})
            Length=[int64]$item.Length
            SizeText=(Format-SjcGuiSize $item.Length)
            StateText=$(if($isKept){'保留'}else{'待处理'})
            IsKept=$isKept
            IsSelected=$s.CandidateSelection.ContainsKey($item.Id)
        }
    })
    $u.CandidatesList.ItemsSource=$rows
    if($u.CandidatesEmpty){$u.CandidatesEmpty.Visibility=if($rows.Count -eq 0){'Visible'}else{'Collapsed'}}
    $selected=@($rows|Where-Object IsSelected)
    if($u.SelectedPathText){$u.SelectedPathText.Text=if($selected.Count -gt 0){($selected|ForEach-Object Path) -join "`r`n"}else{'选中一个文件后显示完整路径'}}
    $categories=if($s.Scan){@($s.Scan.Categories)}else{@($s.Rules|Where-Object{$s.Selected.Contains($_.Id)}|ForEach-Object{[pscustomobject]@{Name=$_.Name;Count=0;Bytes=0;Status='Pending';RuleId=$_.Id}})}
    $u.CategoryList.ItemsSource=@($categories|ForEach-Object{
        $status=@{Success='已扫描';Partial='部分完成(已发现量)';Missing='目录不存在,跳过';RunningProcess='应用运行中,跳过';Failed='读取失败';Cancelled='扫描已取消';Pending='尚未扫描'}[[string]$_.Status]
        if(-not $status){$status=[string]$_.Status}
        [pscustomobject]@{Name=$_.Name;StatusText=$status;SizeText=$(if($_.Status -in @('Success','Partial')){Format-SjcGuiSize $_.Bytes}else{'—'});CountText=$(if($_.Status -in @('Success','Partial')){[string]$_.Count+' 个文件'}else{'未统计'})}
    })
    $historySelection=$u.HistoryList.SelectedItem
    $u.HistoryList.ItemsSource=@($s.History.ToArray())
    if($historySelection){$u.HistoryList.SelectedItem=$historySelection}
    if($u.HistoryEmpty){$u.HistoryEmpty.Visibility=if($s.History.Count -eq 0){'Visible'}else{'Collapsed'}}
    Set-SjcGuiStatus $App $s.Status
}
function Show-SjcGuiDetails {
    param($App,[string]$Text)
    $window=[Windows.Window]::new();$window.Title='任务详情';$window.Width=760;$window.Height=480;$window.Owner=$App.Ui.Window;$window.WindowStartupLocation='CenterOwner'
    $box=[Windows.Controls.TextBox]::new();$box.IsReadOnly=$true;$box.TextWrapping='Wrap';$box.VerticalScrollBarVisibility='Auto';$box.Text=$Text;$box.Padding='14';$window.Content=$box
    [void]$window.ShowDialog()
}
function Confirm-SjcGui {
    param($App,[string]$Text)
    if($App.State.TestMode){return $false}
    return ([Windows.MessageBox]::Show($App.Ui.Window,$Text,'请确认','YesNo','Warning','No') -eq 'Yes')
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
    $App.State.Busy=$true;Set-SjcGuiStatus $App ('正在后台处理：'+$Kind+'，界面仍可切换页面。');Update-SjcGuiView $App
}
function Start-SjcGuiTask {
    param($App,[ValidateSet('Scan','Clean','Recycle')][string]$Action)
    $s=$App.State
    if($s.Busy){throw '已有任务正在运行。'}
    if($s.TestMode){throw '隔离界面模式不允许启动生产 Worker。'}
    if($Action -eq 'Scan'){$task=New-SjcTaskDirectory $s.Context}else{if($Action -eq 'Clean'){$task=$s.TaskDirectory}else{$task=New-SjcTaskDirectory $s.Context}}
    $id=[guid]::NewGuid().ToString('N').Substring(0,8);$prefix='gui-'+$Action.ToLower()+'-'+$id
    $payloadPath=Join-Path $task ($prefix+'.payload.json');$outputPath=Join-Path $task ($prefix+'.output.json');$progress=Join-Path $task ($prefix+'.progress.json');$cancel=Join-Path $task ($prefix+'.cancel')
    $payload=[ordered]@{TaskDirectory=$task;ProgressPath=$progress;CancelPath=$cancel}
    if($Action -eq 'Scan'){$payload.RuleIds=[string[]]@($s.Selected)}
    if($Action -eq 'Clean'){$payload.ExcludedIds=[string[]]@($s.Excluded.Keys);$payload.RecycleMode=[bool]$s.RecycleMode}
    Write-SjcAtomicText $payloadPath ($payload|ConvertTo-Json -Depth 5 -Compress) -NoOverwrite
    $spec=Get-SjcGuiLaunchSpec $Action $payloadPath $outputPath
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$spec.FileName;$info.Arguments=$spec.Arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try{if(-not $process.Start()){throw '无法启动后台进程。'}}catch{$process.Dispose();throw}
    $s.Task=@{Action=$Action;TaskDirectory=$task;Process=$process;OutputPath=$outputPath;ProgressPath=$progress;CancelPath=$cancel;CancelRequested=$false;CancelAt=$null;Forced=$false;RuleIds=[string[]]@($s.Selected)}
    $s.Busy=$true;if($Action -eq 'Scan'){$s.Scan=$null;$s.Stale=$true;$s.PageItems=@();$s.Excluded.Clear();$s.CandidateSelection.Clear()}
    Set-SjcGuiStatus $App ('后台任务已启动：'+$Action);Update-SjcGuiView $App
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
                'Page' {$s.PageOffset=$job.Arguments.Offset;$s.PageItems=@($result.Items)}
                'RuleKeep' {foreach($item in @($result.Items)){if($job.Arguments.Keep){$s.Excluded[$item.Id]=[int64]$item.Length}else{$s.Excluded.Remove($item.Id)}}}
                'Export' {Set-SjcGuiStatus $App ('完整导出 '+$result.ExportedCount+' 条候选至 '+$result.Destination)}
            }
            if($job.Kind -notin @('Export','Close')){Set-SjcGuiStatus $App '候选操作完成。预览缓存不替代清理前校验。'}
        }catch{$s.PendingScan=$false;Set-SjcGuiStatus $App ('候选操作失败或已取消：'+$_.Exception.Message)}
        finally{$job.PowerShell.Dispose();$job.Cancel.Dispose();$s.LocalJob=$null;$s.Busy=$false;Update-SjcGuiView $App}
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
                'ScanButton' {if($s.Background -and $s.Background.Shared.Preview){$s.PendingScan=$true;Start-SjcGuiLocalJob $App 'Close' @{};Set-SjcGuiStatus $App '正在释放旧预览,然后开始新扫描。'}else{Start-SjcGuiTask $App 'Scan'}}
                'CleanButton' {if(Test-SjcGuiCleanable $s){if(Confirm-SjcGui $App ('将处理 '+($s.Scan.CandidateCount-$s.Excluded.Count)+' 个候选,模式: '+$(if($s.RecycleMode){'移入回收站(不立即释放空间)'}else{'永久删除,无法从回收站恢复'})+'。文件变化或校验失败时跳过,是否继续?')){Start-SjcGuiTask $App 'Clean'}}}
                'EmptyRecycleButton' {if(Confirm-SjcGui $App '永久清空当前可访问回收站,不能恢复。Windows还会再次确认。是否继续?'){Start-SjcGuiTask $App 'Recycle'}}
                'KeepButton' {foreach($row in @($u.CandidatesList.Items)){if($row.IsSelected){$s.CandidateSelection[$row.Id]=$row.Path;if(-not $row.IsKept){$s.Excluded[$row.Id]=[int64]$row.Length}}};Update-SjcGuiView $App}
                'RestoreButton' {foreach($row in @($u.CandidatesList.Items)){if($row.IsSelected){$s.CandidateSelection[$row.Id]=$row.Path;if($row.IsKept){$s.Excluded.Remove($row.Id)}}};Update-SjcGuiView $App}
                'CopyPathButton' {$paths=@($u.CandidatesList.Items|Where-Object IsSelected|ForEach-Object Path);if($paths.Count){[Windows.Clipboard]::SetText(($paths -join "`r`n"));Set-SjcGuiStatus $App ('已复制 '+$paths.Count+' 条路径。')}}
                'PreviousButton' {Start-SjcGuiLocalJob $App 'Page' @{Offset=[math]::Max(0,$s.PageOffset-$s.PageSize)}}
                'NextButton' {Start-SjcGuiLocalJob $App 'Page' @{Offset=($s.PageOffset+$s.PageSize)}}
                'ExportButton' {$dialog=[Microsoft.Win32.SaveFileDialog]::new();$dialog.Filter='CSV files (*.csv)|*.csv';$dialog.FileName='清理候选_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.csv';if($dialog.ShowDialog($u.Window)){Start-SjcGuiLocalJob $App 'Export' @{PlanPath=$s.Scan.PlanPath;Destination=$dialog.FileName;ExcludedIds=[string[]]@($s.Excluded.Keys)}}}
                'RecommendedButton' {foreach($row in $s.Draft){$row.Selected=$row.Recommended};$u.RulesList.Items.Refresh()}
                'SelectGroupButton' {$current=$u.RulesList.SelectedItem;if($current){$grp=$current.Group;foreach($item in $s.Draft){if($item.Group -eq $grp){$item.Selected=$true}};$u.RulesList.Items.Refresh()}}
                'ClearGroupButton' {$current=$u.RulesList.SelectedItem;if($current){$grp=$current.Group;foreach($item in $s.Draft){if($item.Group -eq $grp){$item.Selected=$false}};$u.RulesList.Items.Refresh()}}
                'ApplyRulesButton' {$s.Selected.Clear();foreach($row in $s.Draft){if($row.Selected){[void]$s.Selected.Add($row.Id)}};$s.Stale=$true;$s.PageItems=@();Save-SjcGuiPreferences $App;Set-SjcGuiStatus $App '范围已应用。旧扫描失效,需重新扫描。';Update-SjcGuiView $App}
                'CancelRulesButton' {Set-SjcGuiDraft $App;Set-SjcGuiStatus $App '已放弃规则草稿修改。'}
                'KeepRuleButton' {$current=$u.RulesList.SelectedItem;if($current -and (Test-SjcGuiCleanable $s)){Start-SjcGuiLocalJob $App 'RuleKeep' @{RuleId=$current.Id;Keep=$true}}}
                'RestoreRuleButton' {$current=$u.RulesList.SelectedItem;if($current -and (Test-SjcGuiCleanable $s)){Start-SjcGuiLocalJob $App 'RuleKeep' @{RuleId=$current.Id;Keep=$false}}}
                'OpenLogButton' {$selected=$u.HistoryList.SelectedItem;if($selected -and $selected.LogPath -and [IO.File]::Exists($selected.LogPath)){[void][Diagnostics.Process]::Start('notepad.exe',('"'+$selected.LogPath+'"'))}}
                'DetailsButton' {$selected=$u.HistoryList.SelectedItem;if($selected){Show-SjcGuiDetails $App ($selected.Result|ConvertTo-Json -Depth 10)}}
                'RemovePreviewButton' {$selected=$u.HistoryList.SelectedItem;if($selected -and $selected.TaskDirectory -ne $s.TaskDirectory -and (Confirm-SjcGui $App '仅移除选中已放弃任务的预览/通道记录,不删除目标文件和日志。继续?')){[void](Remove-SjcTaskDirectory $s.Context $selected.TaskDirectory);Set-SjcGuiStatus $App '已移除任务预览记录,日志仍保留。'}}
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
    $context=New-SjcContext;$state=New-SjcGuiState $context
    $warning=''
    try{$preferences=Read-SjcPreferences $context;if($preferences){$state.RecycleMode=$preferences.RecycleMode;$state.Selected.Clear();foreach($id in $preferences.SelectedRuleIds){[void]$state.Selected.Add($id)}}}catch{$warning='设置读取失败，使用推荐范围：'+$_.Exception.Message}
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
function Test-SjcGui {
    param([string]$PlanPath,[string]$ScreenshotDirectory)
    $passed=New-Object 'System.Collections.Generic.List[string]';$failed=New-Object 'System.Collections.Generic.List[string]';$skipped=New-Object 'System.Collections.Generic.List[string]';$app=$null;$session=$null
    try{
        Initialize-SjcDesktop
        $context=if($PlanPath){Get-SjcPlanContext ([IO.Path]::GetDirectoryName($PlanPath))}else{New-SjcTestSandbox|ForEach-Object Context}
        $s=New-SjcGuiState $context -TestMode;$app=New-SjcGuiApp $s
        foreach($name in @('Home','Files','Rules','Logs')){Set-SjcGuiPage $app $name;if($app.Ui[($name+'Page')].Visibility -ne 'Visible'){throw '导航页未显示: '+$name}}
        [void]$passed.Add('四页真实WPF控件导航')
        $before=@($s.Selected);foreach($row in $s.Draft){$row.Selected=$false};Invoke-SjcGuiCommand $app 'CancelRulesButton'
        if(@($s.Draft|Where-Object Selected).Count -ne $before.Count){throw '规则草稿取消没有恢复'}
        [void]$passed.Add('规则草稿取消不改变已应用范围')
        if($s.Draft.Count -gt 1){
            $current=$s.Draft[-1];$app.Ui.RulesList.SelectedItem=$current
            Invoke-SjcGuiCommand $app 'SelectGroupButton'
            if(@($s.Draft|Where-Object{$_.Group -eq $current.Group -and -not $_.Selected}).Count){throw '当前组选取错误'}
            Invoke-SjcGuiCommand $app 'ClearGroupButton'
            if(@($s.Draft|Where-Object{$_.Group -eq $current.Group -and $_.Selected}).Count){throw '当前组清空错误'}
            Invoke-SjcGuiCommand $app 'CancelRulesButton'
            [void]$passed.Add('当前规则选择与启用独立，分组全选清空准确')
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
            $s.Scan=[pscustomobject]@{Status='Success';CandidateCount=$session.Count;CandidateBytes=$session.Bytes;PlanPath=$PlanPath;Categories=@()};$s.Stale=$false;$s.PageItems=$items;Update-SjcGuiView $app
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
                [void]$passed.Add('选中与保留独立、保留恢复及完整路径详情')
            }
            [void]$passed.Add('T17 真实封存计划分页与保留统计')
            Close-SjcPreviewSession $session;$session=$null
        }else{[void]$skipped.Add('未给PlanPath,真实分页未测')}
        foreach($size in @(@(1200,820),@(960,700))){
            $app.Ui.Window.Width=$size[0];$app.Ui.Window.Height=$size[1];Set-SjcGuiPage $app 'Home'
            $visual=$app.Ui.Window.Content;$visual.Measure([Windows.Size]::new($size[0],$size[1]));$visual.Arrange([Windows.Rect]::new(0,0,$size[0],$size[1]));$visual.UpdateLayout()
            if($app.Ui.ScanButton.ActualHeight -lt 30 -or $app.Ui.ScanButton.ActualWidth -lt 50){throw '主按钮未获得完整布局空间'}
            [void]$passed.Add(('主按钮布局 {0}x{1}' -f $size[0],$size[1]))
        }
        if($ScreenshotDirectory){
            [void][IO.Directory]::CreateDirectory($ScreenshotDirectory);$app.Ui.Window.Width=1200;$app.Ui.Window.Height=820
            foreach($page in @('Home','Files','Rules','Logs')){Set-SjcGuiPage $app $page;Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory ($page+'.png'))}
            $app.Ui.Window.Width=960;$app.Ui.Window.Height=700;Set-SjcGuiPage $app 'Home'
            Save-SjcGuiRender $app.Ui.Window (Join-Path $ScreenshotDirectory 'Home-960x700.png')
        }
        [void]$skipped.Add('真实显示器DPI/回收站系统确认需要非破坏性单独验收')
    }catch{[void]$failed.Add($_.Exception.Message+' @ '+$_.ScriptStackTrace)}
    finally{if($session){Close-SjcPreviewSession $session};if($app){Remove-SjcGuiApp $app;$app.Ui.Window.Close()}}
    return [pscustomobject]@{Name='Test-SjcGui';Version=(Get-SjcVersion);Status=$(if($failed.Count){'Failed'}else{'Success'});Passed=[string[]]$passed.ToArray();Failed=[string[]]$failed.ToArray();Skipped=[string[]]$skipped.ToArray()}
}
