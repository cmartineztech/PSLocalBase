<#
.SYNOPSIS
    PSLocalBase Playground - Modern Windows Desktop NoSQL Database Explorer
.DESCRIPTION
    Interactive GUI Playground for PSLocalBase built with native PowerShell + WPF.
    Adopts the clean Windows enterprise design system and color palette from LiteDeploy.DynamicDrivers
    with 100% full Dark Mode & Light Mode support, custom-styled chevron ComboBox dropdowns,
    and a dual-pane layout (interactive code cards on the left, live database explorer & console on the right).
.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\Playground\Playground.ps1
    pwsh -ExecutionPolicy Bypass -File .\Playground\Playground.ps1 -DarkMode
    powershell.exe -ExecutionPolicy Bypass -File .\Playground\Playground.ps1
#>

[CmdletBinding()]
param(
    [string]$DatabasePath = "playground.db",
    [switch]$DarkMode
)

# ---------------------------------------------------------------------------
# Pre-Flight: Ensure STA Mode for WPF
# ---------------------------------------------------------------------------
function Start-PlaygroundApp {
    param(
        [string]$DbPath,
        [bool]$StartInDark = $false
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

    if ($null -eq [System.Windows.Application]::Current) {
        $script:wpfApp = [System.Windows.Application]::new()
        $script:wpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }

    # Locate and import PSLocalBase module
    $parentDir = Split-Path $PSScriptRoot -Parent
    $modulePsd1 = Join-Path $parentDir "PSLocalBase.psd1"
    if (-not (Test-Path $modulePsd1)) {
        $modulePsd1 = Join-Path $PSScriptRoot "PSLocalBase.psd1"
    }
    if (-not (Test-Path $modulePsd1)) {
        throw "Could not find PSLocalBase.psd1 in $parentDir or $PSScriptRoot"
    }
    Import-Module $modulePsd1 -Force

    # Initialize PSLocalBase instance
    $resolvedDbPath = Join-Path $PSScriptRoot $DbPath
    $script:db = [PSLocalBase]::new($resolvedDbPath, @{
        cacheSizeMB = 32
        wal         = $true
        depth       = 20
    })

    # -----------------------------------------------------------------------
    # Color Themes (Exact Palette from LiteDeploy.DynamicDrivers)
    # -----------------------------------------------------------------------
    $script:themeLight = @{
        'BgColor'         = '#F0F4FA'
        'FgColor'         = '#1A2332'
        'SecFgColor'      = '#5C6B7A'
        'MutedFgColor'    = '#7E8CA0'
        'SurfaceBg'       = '#FFFFFF'
        'FooterBg'        = '#F4F7FB'
        'SidebarBg'       = '#E4EDF7'
        'BorderColor'     = '#D0DAE6'
        'ButtonBg'        = '#F7F9FB'
        'ButtonFg'        = '#1A2332'
        'ButtonHoverBg'   = '#E8EEF6'
        'ButtonPressedBg' = '#DCE6F2'
        'TrackBg'         = '#E6EBF2'
        'HeaderColor'     = '#2F6FED'
        'PrimaryHoverBg'  = '#2457D6'
        'PrimaryPressedBg'= '#1D4BB8'
        'DisabledBg'      = '#F3F4F6'
        'DisabledBorder'  = '#E5E7EB'
        'DisabledFg'      = '#9CA3AF'
        'DangerBg'        = '#D13438'
        'DangerHoverBg'   = '#A80000'
        'DangerPressedBg' = '#750000'
        'InputBg'         = '#FFFFFF'
        'LogBg'           = '#F7F9FB'
        'LogFg'           = '#2F6FED'
        'ConsoleCardBg'   = '#FFFFFF'
    }

    $script:themeDark = @{
        'BgColor'         = '#121418'
        'FgColor'         = '#F3F4F6'
        'SecFgColor'      = '#9CA3AF'
        'MutedFgColor'    = '#8A99AD'
        'SurfaceBg'       = '#1C1F26'
        'FooterBg'        = '#181B21'
        'SidebarBg'       = '#171A20'
        'BorderColor'     = '#2C313A'
        'ButtonBg'        = '#242830'
        'ButtonFg'        = '#F3F4F6'
        'ButtonHoverBg'   = '#2E3440'
        'ButtonPressedBg' = '#3A4150'
        'TrackBg'         = '#2D2D2D'
        'HeaderColor'     = '#3B82F6'
        'PrimaryHoverBg'  = '#2563EB'
        'PrimaryPressedBg'= '#1D4ED8'
        'DisabledBg'      = '#262626'
        'DisabledBorder'  = '#333333'
        'DisabledFg'      = '#6B7280'
        'DangerBg'        = '#DC2626'
        'DangerHoverBg'   = '#B91C1C'
        'DangerPressedBg' = '#991B1B'
        'InputBg'         = '#242830'
        'LogBg'           = '#0F1115'
        'LogFg'           = '#60A5FA'
        'ConsoleCardBg'   = '#1C1F26'
    }

    # -----------------------------------------------------------------------
    # XAML Definition (Windows Native LiteDeploy Design System with Theme Keys)
    # -----------------------------------------------------------------------
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSLocalBase Playground - Embedded NoSQL Database Explorer"
        Width="1280" Height="840" MinWidth="1100" MinHeight="720"
        WindowStartupLocation="CenterScreen"
        ShowInTaskbar="True"
        FontFamily="Segoe UI"
        Background="{DynamicResource BgColor}"
        Foreground="{DynamicResource FgColor}">

    <Window.Resources>
        <!-- Primary Button (LiteDeploy Accent) -->
        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource HeaderColor}"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource PrimaryHoverBg}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource PrimaryPressedBg}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Secondary Button (LiteDeploy Outlined Card) -->
        <Style x:Key="SecondaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource SurfaceBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource ButtonHoverBg}"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="{DynamicResource HeaderColor}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource ButtonPressedBg}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Danger Button (LiteDeploy Crimson) -->
        <Style x:Key="DangerButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource DangerBg}"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource DangerHoverBg}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource DangerPressedBg}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Segmented Nav Button Style (from LiteDeploy DynamicDrivers) -->
        <Style x:Key="NavButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MutedFgColor}"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.90"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- LiteDeploy DataGrid Header & Row Styles -->
        <Style x:Key="DataGridHeaderStyle" TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="{DynamicResource FooterBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource MutedFgColor}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        </Style>

        <Style x:Key="DataGridRowStyle" TargetType="DataGridRow">
            <Setter Property="Background" Value="{DynamicResource SurfaceBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonHoverBg}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonPressedBg}"/>
                    <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DataGridCellStyle" TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="Transparent"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- =================================================================== -->
        <!-- LiteDeploy.DynamicDrivers Custom Chevron ComboBox Template          -->
        <!-- =================================================================== -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="item" Background="Transparent" CornerRadius="6" Margin="3,2" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="item" Property="Background" Value="{DynamicResource ButtonHoverBg}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="item" Property="Background" Value="{DynamicResource ButtonPressedBg}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DynamicDriversComboBoxStyle" TargetType="ComboBox">
            <Setter Property="Height" Value="30"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
            <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="box" Background="{DynamicResource InputBg}"
                                                BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6">
                                            <!-- LiteDeploy DynamicDrivers SVG Chevron Path -->
                                            <Path Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource MutedFgColor}" StrokeThickness="1.5"
                                                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                                  Width="8" Height="4" Stretch="Fill"
                                                  HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource HeaderColor}"/>
                                            </Trigger>
                                            <Trigger Property="IsChecked" Value="True">
                                                <Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource HeaderColor}"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>

                            <!-- Selection box content presenter (High Contrast) -->
                            <ContentPresenter IsHitTestVisible="False" Margin="10,0,26,0" VerticalAlignment="Center"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}">
                                <ContentPresenter.Resources>
                                    <Style TargetType="TextBlock">
                                        <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
                                        <Setter Property="FontWeight" Value="SemiBold"/>
                                    </Style>
                                </ContentPresenter.Resources>
                            </ContentPresenter>

                            <!-- Dropdown Popup Card -->
                            <Popup Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                                   IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                                <Border Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="6" Margin="0,4,0,0" Padding="2,2"
                                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                                    <ScrollViewer SnapsToDevicePixels="True" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <!-- Main Windows Application Grid -->
    <Grid Margin="24,18,24,14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Top App Header Bar -->
            <RowDefinition Height="Auto"/> <!-- Segmented Navigation Pills -->
            <RowDefinition Height="*"/>    <!-- Master-Detail Content Area -->
            <RowDefinition Height="26"/>   <!-- Windows Bottom Status Strip -->
        </Grid.RowDefinitions>

        <!-- Row 0: App Header & Quick Management Toolbar -->
        <Grid Grid.Row="0" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- App Title & Identity -->
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <Border Background="{DynamicResource HeaderColor}" CornerRadius="6" Width="28" Height="28" Margin="0,0,10,0">
                    <TextBlock Text="PL" FontSize="13" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock Text="PSLocalBase" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource HeaderColor}" VerticalAlignment="Center"/>
                <TextBlock Text=" Playground" FontSize="18" FontWeight="SemiBold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center"/>
                <Border Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6" Padding="8,3" Margin="14,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="Windows Native (winsqlite3.dll)" FontSize="10.5" FontWeight="SemiBold" Foreground="{DynamicResource SecFgColor}"/>
                </Border>
            </StackPanel>

            <!-- Top Action Buttons & Theme Switcher -->
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button Name="btnToggleTheme" Content="&#x1F319; Dark Mode" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0"/>
                <Button Name="btnSeedDemo" Content="Seed Demo Data" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0"/>
                <Button Name="btnCheckpointWal" Content="Flush WAL Checkpoint" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,8,0"/>
                <Button Name="btnResetDatabase" Content="Reset Database" Style="{StaticResource DangerButtonStyle}"/>
            </StackPanel>
        </Grid>

        <!-- Row 1: Segmented Nav Control (LiteDeploy Signature Capsule) -->
        <Border Grid.Row="1" HorizontalAlignment="Left" VerticalAlignment="Center"
                Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                CornerRadius="8" Padding="3" Margin="0,0,0,14">
            <StackPanel Orientation="Horizontal">
                <Button Name="btnNavAdd" Content="Adding Data" Style="{StaticResource NavButtonStyle}" MinWidth="120"/>
                <Button Name="btnNavGet" Content="Getting Data" Style="{StaticResource NavButtonStyle}" MinWidth="120"/>
                <Button Name="btnNavUpdate" Content="Updating Data" Style="{StaticResource NavButtonStyle}" MinWidth="130"/>
                <Button Name="btnNavDelete" Content="Deleting Data" Style="{StaticResource NavButtonStyle}" MinWidth="120"/>
                <Button Name="btnNavCustom" Content="Custom PowerShell Script" Style="{StaticResource NavButtonStyle}" MinWidth="170"/>
            </StackPanel>
        </Border>

        <!-- Row 2: Split Two-Pane Workspace -->
        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="540" MinWidth="420"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="*" MinWidth="520"/>
            </Grid.ColumnDefinitions>

            <!-- =========================================================== -->
            <!-- LEFT COLUMN: INTERACTIVE CODE CARDS (Windows Card Style)    -->
            <!-- =========================================================== -->
            <Border Grid.Column="0" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="18,16">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/> <!-- Category Title & Collection Picker -->
                        <RowDefinition Height="*"/>    <!-- Scrollable Cards -->
                    </Grid.RowDefinitions>

                    <!-- Category Title & Active Collection Dropdown -->
                    <Grid Grid.Row="0" Margin="0,0,0,14">
                        <TextBlock Name="lblCategoryTitle" Text="Adding Data" FontSize="20" FontWeight="Bold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <TextBlock Text="Target Collection:" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource MutedFgColor}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <ComboBox Name="cmbLeftCollection" Width="130" Style="{StaticResource DynamicDriversComboBoxStyle}"/>
                        </StackPanel>
                    </Grid>

                    <!-- Scrollable Cards Container -->
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="0,0,6,0">
                        <StackPanel Name="panelCardsContainer">

                            <!-- Card 1 -->
                            <Border Name="card1" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,16">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="38"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>

                                    <!-- Card Header -->
                                    <Border Grid.Row="0" Background="{DynamicResource FooterBg}" BorderThickness="0,0,0,1" BorderBrush="{DynamicResource BorderColor}" CornerRadius="7,7,0,0" Padding="14,0">
                                        <Grid VerticalAlignment="Center">
                                            <TextBlock Name="lblCard1Title" Text="Add Document" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center"/>
                                            <Border Background="{DynamicResource ButtonHoverBg}" CornerRadius="4" Padding="6,2" HorizontalAlignment="Right" VerticalAlignment="Center">
                                                <TextBlock Text="PowerShell" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource HeaderColor}"/>
                                            </Border>
                                        </Grid>
                                    </Border>

                                    <!-- Card Code Editor -->
                                    <Border Grid.Row="1" Background="{DynamicResource ButtonBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Margin="12,12,12,0" CornerRadius="6" Padding="12,10">
                                        <TextBox Name="txtCodeCard1" AcceptsReturn="True" AcceptsTab="True" BorderThickness="0"
                                                 Background="Transparent" Foreground="{DynamicResource FgColor}"
                                                 CaretBrush="{DynamicResource FgColor}" FontFamily="Consolas" FontSize="12.5"
                                                 TextWrapping="Wrap"/>
                                    </Border>

                                    <!-- Card Footer with Run Button -->
                                    <Grid Grid.Row="2" Margin="12,10,12,12">
                                        <TextBlock Name="lblCard1Status" Text="" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                        <Button Name="btnRunCard1" Content="RUN CODE &#x25B6;" Style="{StaticResource PrimaryButtonStyle}" HorizontalAlignment="Right"/>
                                    </Grid>
                                </Grid>
                            </Border>

                            <!-- Card 2 -->
                            <Border Name="card2" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,16">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="38"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>

                                    <Border Grid.Row="0" Background="{DynamicResource FooterBg}" BorderThickness="0,0,0,1" BorderBrush="{DynamicResource BorderColor}" CornerRadius="7,7,0,0" Padding="14,0">
                                        <Grid VerticalAlignment="Center">
                                            <TextBlock Name="lblCard2Title" Text="Update Document" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center"/>
                                            <Border Background="{DynamicResource ButtonHoverBg}" CornerRadius="4" Padding="6,2" HorizontalAlignment="Right" VerticalAlignment="Center">
                                                <TextBlock Text="PowerShell" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource HeaderColor}"/>
                                            </Border>
                                        </Grid>
                                    </Border>

                                    <Border Grid.Row="1" Background="{DynamicResource ButtonBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Margin="12,12,12,0" CornerRadius="6" Padding="12,10">
                                        <TextBox Name="txtCodeCard2" AcceptsReturn="True" AcceptsTab="True" BorderThickness="0"
                                                 Background="Transparent" Foreground="{DynamicResource FgColor}"
                                                 CaretBrush="{DynamicResource FgColor}" FontFamily="Consolas" FontSize="12.5"
                                                 TextWrapping="Wrap"/>
                                    </Border>

                                    <Grid Grid.Row="2" Margin="12,10,12,12">
                                        <TextBlock Name="lblCard2Status" Text="" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                        <Button Name="btnRunCard2" Content="RUN CODE &#x25B6;" Style="{StaticResource PrimaryButtonStyle}" HorizontalAlignment="Right"/>
                                    </Grid>
                                </Grid>
                            </Border>

                            <!-- Card 3 -->
                            <Border Name="card3" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="8" Margin="0,0,0,16">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="38"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>

                                    <Border Grid.Row="0" Background="{DynamicResource FooterBg}" BorderThickness="0,0,0,1" BorderBrush="{DynamicResource BorderColor}" CornerRadius="7,7,0,0" Padding="14,0">
                                        <Grid VerticalAlignment="Center">
                                            <TextBlock Name="lblCard3Title" Text="Advanced Query" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center"/>
                                            <Border Background="{DynamicResource ButtonHoverBg}" CornerRadius="4" Padding="6,2" HorizontalAlignment="Right" VerticalAlignment="Center">
                                                <TextBlock Text="PowerShell" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource HeaderColor}"/>
                                            </Border>
                                        </Grid>
                                    </Border>

                                    <Border Grid.Row="1" Background="{DynamicResource ButtonBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Margin="12,12,12,0" CornerRadius="6" Padding="12,10">
                                        <TextBox Name="txtCodeCard3" AcceptsReturn="True" AcceptsTab="True" BorderThickness="0"
                                                 Background="Transparent" Foreground="{DynamicResource FgColor}"
                                                 CaretBrush="{DynamicResource FgColor}" FontFamily="Consolas" FontSize="12.5"
                                                 TextWrapping="Wrap"/>
                                    </Border>

                                    <Grid Grid.Row="2" Margin="12,10,12,12">
                                        <TextBlock Name="lblCard3Status" Text="" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                        <Button Name="btnRunCard3" Content="RUN CODE &#x25B6;" Style="{StaticResource PrimaryButtonStyle}" HorizontalAlignment="Right"/>
                                    </Grid>
                                </Grid>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </Border>

            <!-- =========================================================== -->
            <!-- RIGHT COLUMN: DATABASE EXPLORER & LIVE EXECUTION LOG       -->
            <!-- =========================================================== -->
            <Grid Grid.Column="2">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*" MinHeight="260"/>  <!-- Upper: Database State Explorer -->
                    <RowDefinition Height="12"/>                  <!-- Spacing -->
                    <RowDefinition Height="250" MinHeight="160"/> <!-- Lower: Live Execution Log -->
                </Grid.RowDefinitions>

                <!-- Upper Card: Database State Explorer -->
                <Border Grid.Row="0" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16,14">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/> <!-- Explorer Header & Toolbar -->
                            <RowDefinition Height="*"/>    <!-- DataGrid -->
                            <RowDefinition Height="Auto"/> <!-- Explorer Footer -->
                        </Grid.RowDefinitions>

                        <!-- Explorer Header Toolbar -->
                        <Grid Grid.Row="0" Margin="0,0,0,12">
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock Text="Database Explorer" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                <TextBlock Text="Collection:" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource MutedFgColor}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                <ComboBox Name="cmbRightCollection" Width="130" Style="{StaticResource DynamicDriversComboBoxStyle}" Margin="0,0,10,0"/>
                            </StackPanel>

                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                <TextBox Name="txtKeySearch" Width="140" Height="30" FontSize="11.5" Padding="8,5" Margin="0,0,8,0"
                                         Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource BorderColor}"
                                         Foreground="{DynamicResource FgColor}" CaretBrush="{DynamicResource FgColor}"
                                         Text="Search key or text..."/>
                                <Button Name="btnRefreshTable" Content="Refresh" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,6,0"/>
                                <Button Name="btnClearCollection" Content="Clear Collection" Style="{StaticResource SecondaryButtonStyle}" Margin="0,0,6,0"/>
                                <Button Name="btnDeleteDoc" Content="Delete Selected" Style="{StaticResource DangerButtonStyle}"/>
                            </StackPanel>
                        </Grid>

                        <!-- Modern DataGrid Table -->
                        <Border Grid.Row="1" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6">
                            <DataGrid Name="dgDocuments" AutoGenerateColumns="False" IsReadOnly="True"
                                      Background="Transparent" BorderThickness="0" GridLinesVisibility="Horizontal"
                                      HorizontalGridLinesBrush="{DynamicResource BorderColor}" SelectionMode="Single" FontSize="12" RowHeight="32"
                                      ColumnHeaderStyle="{StaticResource DataGridHeaderStyle}"
                                      RowStyle="{StaticResource DataGridRowStyle}"
                                      CellStyle="{StaticResource DataGridCellStyle}"
                                      HeadersVisibility="Column" RowHeaderWidth="0">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="#" Binding="{Binding Index}" Width="45"/>
                                    <DataGridTextColumn Header="Document ID / Key" Binding="{Binding Key}" Width="160">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="Foreground" Value="{DynamicResource HeaderColor}"/>
                                                <Setter Property="FontWeight" Value="SemiBold"/>
                                                <Setter Property="FontFamily" Value="Consolas"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Document Data (JSON)" Binding="{Binding ValueJson}" Width="*">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="Foreground" Value="{DynamicResource FgColor}"/>
                                                <Setter Property="FontFamily" Value="Consolas"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Border>

                        <!-- Explorer Footer -->
                        <Grid Grid.Row="2" Margin="0,8,0,0">
                            <TextBlock Name="lblTotalEntries" Text="Total entries: 0" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource SecFgColor}" VerticalAlignment="Center"/>
                            <TextBlock Name="lblDbMetrics" Text="Storage: playground.db (WAL Mode)" FontSize="11.5" Foreground="{DynamicResource MutedFgColor}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                        </Grid>
                    </Grid>
                </Border>

                <!-- Lower Card: Live Execution Log & Console -->
                <Border Grid.Row="2" Background="{DynamicResource SurfaceBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="10" Padding="16,12">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/> <!-- Log Toolbar -->
                            <RowDefinition Height="*"/>    <!-- Scrollable Messages -->
                            <RowDefinition Height="Auto"/> <!-- Interactive CLI Prompt -->
                        </Grid.RowDefinitions>

                        <!-- Log Header Toolbar -->
                        <Grid Grid.Row="0" Margin="0,0,0,8">
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                <TextBlock Text="Execution Output &amp; Console" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource FgColor}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <Border Name="badgeStatus" Background="{DynamicResource ButtonHoverBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="4" Padding="6,2">
                                    <TextBlock Name="txtStatusBadge" Text="Ready" FontSize="10.5" FontWeight="Bold" Foreground="{DynamicResource HeaderColor}"/>
                                </Border>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                <TextBlock Name="txtConsolePerf" Text="0.00 ms" FontSize="11" Foreground="{DynamicResource MutedFgColor}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                <Button Name="btnClearLogs" Content="Clear Logs" Style="{StaticResource SecondaryButtonStyle}" Padding="8,3" FontSize="11"/>
                            </StackPanel>
                        </Grid>

                        <!-- Console Messages List -->
                        <Border Grid.Row="1" Background="{DynamicResource LogBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6" Margin="0,0,0,8">
                            <ScrollViewer Name="scrollConsole" VerticalScrollBarVisibility="Auto" Padding="10,6">
                                <StackPanel Name="panelConsoleLogs"/>
                            </ScrollViewer>
                        </Border>

                        <!-- Interactive CLI Input (>) -->
                        <Border Grid.Row="2" Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="6" Padding="8,2">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="18"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="&gt;" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource HeaderColor}" VerticalAlignment="Center"/>
                                <TextBox Name="txtConsoleInput" Grid.Column="1" Height="24" BorderThickness="0" Background="Transparent"
                                         FontFamily="Consolas" FontSize="12" Foreground="{DynamicResource FgColor}" CaretBrush="{DynamicResource FgColor}"
                                         VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <!-- Row 3: Windows Status Strip -->
        <Grid Grid.Row="3" Margin="4,6,4,0">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="&#x25CF;" FontSize="10" Foreground="#2E7D32" Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock Name="txtStatusMsg" Text="Connected: winsqlite3.dll | Database: playground.db" FontSize="11" Foreground="{DynamicResource MutedFgColor}" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock Name="txtMemoryUsage" Text="CLR Memory: 0 MB" FontSize="11" Foreground="{DynamicResource MutedFgColor}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
    </Grid>
</Window>
"@

    # -----------------------------------------------------------------------
    # Parse & Load Window
    # -----------------------------------------------------------------------
    $xmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    try {
        $script:window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    } finally {
        $xmlReader.Dispose()
    }

    # -----------------------------------------------------------------------
    # Element Handles
    # -----------------------------------------------------------------------
    $btnToggleTheme   = $script:window.FindName("btnToggleTheme")
    $btnNavAdd        = $script:window.FindName("btnNavAdd")
    $btnNavGet        = $script:window.FindName("btnNavGet")
    $btnNavUpdate     = $script:window.FindName("btnNavUpdate")
    $btnNavDelete     = $script:window.FindName("btnNavDelete")
    $btnNavCustom     = $script:window.FindName("btnNavCustom")
    $btnSeedDemo      = $script:window.FindName("btnSeedDemo")
    $btnCheckpointWal = $script:window.FindName("btnCheckpointWal")
    $btnResetDatabase = $script:window.FindName("btnResetDatabase")

    $lblCategoryTitle = $script:window.FindName("lblCategoryTitle")
    $cmbLeftCollection= $script:window.FindName("cmbLeftCollection")
    $cmbRightCollection=$script:window.FindName("cmbRightCollection")
    $txtKeySearch     = $script:window.FindName("txtKeySearch")

    $card1            = $script:window.FindName("card1")
    $card2            = $script:window.FindName("card2")
    $card3            = $script:window.FindName("card3")
    $lblCard1Title    = $script:window.FindName("lblCard1Title")
    $lblCard2Title    = $script:window.FindName("lblCard2Title")
    $lblCard3Title    = $script:window.FindName("lblCard3Title")
    $txtCodeCard1     = $script:window.FindName("txtCodeCard1")
    $txtCodeCard2     = $script:window.FindName("txtCodeCard2")
    $txtCodeCard3     = $script:window.FindName("txtCodeCard3")
    $btnRunCard1      = $script:window.FindName("btnRunCard1")
    $btnRunCard2      = $script:window.FindName("btnRunCard2")
    $btnRunCard3      = $script:window.FindName("btnRunCard3")
    $lblCard1Status   = $script:window.FindName("lblCard1Status")
    $lblCard2Status   = $script:window.FindName("lblCard2Status")
    $lblCard3Status   = $script:window.FindName("lblCard3Status")

    $dgDocuments      = $script:window.FindName("dgDocuments")
    $lblTotalEntries  = $script:window.FindName("lblTotalEntries")
    $lblDbMetrics     = $script:window.FindName("lblDbMetrics")
    $btnRefreshTable  = $script:window.FindName("btnRefreshTable")
    $btnClearCollection=$script:window.FindName("btnClearCollection")
    $btnDeleteDoc     = $script:window.FindName("btnDeleteDoc")

    $panelConsoleLogs = $script:window.FindName("panelConsoleLogs")
    $scrollConsole    = $script:window.FindName("scrollConsole")
    $btnClearLogs     = $script:window.FindName("btnClearLogs")
    $txtConsoleInput  = $script:window.FindName("txtConsoleInput")
    $txtConsolePerf   = $script:window.FindName("txtConsolePerf")
    $txtStatusBadge   = $script:window.FindName("txtStatusBadge")
    $txtStatusMsg     = $script:window.FindName("txtStatusMsg")
    $txtMemoryUsage   = $script:window.FindName("txtMemoryUsage")

    $script:activeCollection = "users"
    $script:currentCategory = "Adding Data"
    $script:updatingDropdowns = $false
    $script:isDarkMode = $false

    # -----------------------------------------------------------------------
    # Theme Application Engine (Supports Dynamic Switching)
    # -----------------------------------------------------------------------
    function Set-AppTheme([bool]$DarkModeEnabled) {
        $script:isDarkMode = $DarkModeEnabled
        $palette = if ($DarkModeEnabled) { $script:themeDark } else { $script:themeLight }

        $brushConverter = [System.Windows.Media.BrushConverter]::new()
        foreach ($key in $palette.Keys) {
            $script:window.Resources[$key] = $brushConverter.ConvertFromString($palette[$key])
        }

        # Update button text & icon
        if ($DarkModeEnabled) {
            $btnToggleTheme.Content = "$([char]0x2600) Light Mode"
        } else {
            $btnToggleTheme.Content = "$([char]0x1F319) Dark Mode"
        }

        # Re-apply category active tab styling
        Set-PlaygroundCategory $script:currentCategory
    }

    # -----------------------------------------------------------------------
    # Logging into Output Console
    # -----------------------------------------------------------------------
    function Log-ToConsole([string]$Message, [object]$Data = $null, [double]$DurationMs = -1) {
        $logGrid = [System.Windows.Controls.Grid]::new()
        $logGrid.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)

        $col0 = [System.Windows.Controls.ColumnDefinition]::new()
        $col0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $col1 = [System.Windows.Controls.ColumnDefinition]::new()
        $col1.Width = [System.Windows.GridLength]::Auto
        $logGrid.ColumnDefinitions.Add($col0)
        $logGrid.ColumnDefinitions.Add($col1)

        $leftStack = [System.Windows.Controls.StackPanel]::new()
        $leftStack.Orientation = [System.Windows.Controls.Orientation]::Vertical

        $headerRow = [System.Windows.Controls.StackPanel]::new()
        $headerRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal

        # Accent "PSLocalBase" badge
        $badge = [System.Windows.Controls.Border]::new()
        $badge.Background = $script:window.Resources["HeaderColor"]
        $badge.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $badge.Padding = [System.Windows.Thickness]::new(5, 1, 5, 1)
        $badge.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
        $badgeTxt = [System.Windows.Controls.TextBlock]::new()
        $badgeTxt.Text = "PSLocalBase"
        $badgeTxt.FontSize = 10
        $badgeTxt.FontWeight = [System.Windows.FontWeights]::Bold
        $badgeTxt.Foreground = [System.Windows.Media.Brushes]::White
        $badge.Child = $badgeTxt
        [void]$headerRow.Children.Add($badge)

        $msgTxt = [System.Windows.Controls.TextBlock]::new()
        $msgTxt.Text = $Message
        $msgTxt.FontSize = 12
        $msgTxt.Foreground = $script:window.Resources["FgColor"]
        $msgTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
        [void]$headerRow.Children.Add($msgTxt)
        [void]$leftStack.Children.Add($headerRow)

        # Indented formatted object data
        if ($null -ne $Data) {
            $jsonStr = try { $Data | ConvertTo-Json -Depth 6 -Compress } catch { "$Data" }
            $dataTxt = [System.Windows.Controls.TextBlock]::new()
            $dataTxt.Text = "  $([char]0x25B8) $jsonStr"
            $dataTxt.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
            $dataTxt.FontSize = 11.5
            $dataTxt.Foreground = $script:window.Resources["LogFg"]
            $dataTxt.Margin = [System.Windows.Thickness]::new(6, 2, 0, 0)
            $dataTxt.TextWrapping = [System.Windows.TextWrapping]::Wrap
            [void]$leftStack.Children.Add($dataTxt)
        }

        [System.Windows.Controls.Grid]::SetColumn($leftStack, 0)
        [void]$logGrid.Children.Add($leftStack)

        # Right timestamp and timing
        $timeTxt = [System.Windows.Controls.TextBlock]::new()
        $stamp = (Get-Date).ToString("HH:mm:ss")
        $timeTxt.Text = if ($DurationMs -ge 0) { "$($DurationMs)ms" } else { $stamp }
        $timeTxt.FontSize = 10.5
        $timeTxt.Foreground = $script:window.Resources["MutedFgColor"]
        $timeTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
        [System.Windows.Controls.Grid]::SetColumn($timeTxt, 1)
        [void]$logGrid.Children.Add($timeTxt)

        [void]$panelConsoleLogs.Children.Add($logGrid)
        $scrollConsole.ScrollToEnd()
    }

    # -----------------------------------------------------------------------
    # Table & Storage State Loader
    # -----------------------------------------------------------------------
    function Refresh-DatabaseState {
        $colls = @($script:db.listCollections())
        if ($colls.Count -eq 0) {
            $colls = @("users")
        }

        if (-not ($colls -contains $script:activeCollection)) {
            $script:activeCollection = $colls[0]
        }

        # Populate dropdowns cleanly with high-contrast text
        $script:updatingDropdowns = $true
        try {
            $cmbLeftCollection.Items.Clear()
            $cmbRightCollection.Items.Clear()
            foreach ($c in $colls) {
                [void]$cmbLeftCollection.Items.Add($c)
                [void]$cmbRightCollection.Items.Add($c)
            }
            $cmbLeftCollection.SelectedItem = $script:activeCollection
            $cmbRightCollection.SelectedItem = $script:activeCollection
        } finally {
            $script:updatingDropdowns = $false
        }

        Load-CollectionDocuments $script:activeCollection
    }

    function Load-CollectionDocuments([string]$CollectionName) {
        $filterKey = $txtKeySearch.Text.Trim()
        if ($filterKey -eq "Search key or text...") { $filterKey = "" }

        $docsWithKeys = @($script:db.collection($CollectionName).get(@{ keys = $true }))
        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

        for ($i = 0; $i -lt $docsWithKeys.Count; $i++) {
            $item = $docsWithKeys[$i]
            $keyStr = [string]$item.key
            $dataObj = $item.data
            $compactJson = try { $dataObj | ConvertTo-Json -Depth 5 -Compress } catch { "$dataObj" }

            if ($filterKey -and (-not $keyStr.ToLower().Contains($filterKey.ToLower())) -and (-not $compactJson.ToLower().Contains($filterKey.ToLower()))) {
                continue
            }

            $rows.Add([PSCustomObject]@{
                Index     = $i + 1
                Key       = $keyStr
                RawKey    = $keyStr
                ValueJson = $compactJson
                DataObj   = $dataObj
            })
        }

        $dgDocuments.ItemsSource = $rows
        $lblTotalEntries.Text = "Total entries: $($rows.Count) in collection '$CollectionName'"

        # File metrics
        $dbFile = Join-Path $PSScriptRoot $DbPath
        if (Test-Path $dbFile) {
            $kb = [math]::Round((Get-Item $dbFile).Length / 1KB, 1)
            $lblDbMetrics.Text = "Storage: $($DbPath) ($kb KB | WAL Mode)"
        }

        # CLR memory
        $memMB = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
        $txtMemoryUsage.Text = "CLR Memory: $memMB MB"
    }

    # -----------------------------------------------------------------------
    # Code Execution Engine
    # -----------------------------------------------------------------------
    function Execute-CodeSnippet([string]$Code, [System.Windows.Controls.TextBlock]$StatusLabel) {
        if (-not $Code.Trim()) { return }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = $null

        try {
            $db = $script:db
            $scriptBlock = [scriptblock]::Create($Code)
            $res = & $scriptBlock
            $sw.Stop()

            $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            $txtConsolePerf.Text = "$($ms) ms"
            $txtStatusBadge.Text = "Success"
            $txtStatusBadge.Foreground = [System.Windows.Media.Brushes]::ForestGreen

            if ($null -ne $StatusLabel) {
                $StatusLabel.Text = "$([char]0x2714) Done in $($ms)ms"
                $StatusLabel.Foreground = [System.Windows.Media.Brushes]::ForestGreen
            }

            $countStr = ""
            if ($null -ne $res -and ($res -is [System.Collections.ICollection] -or $res -is [System.Array])) {
                $countStr = " ($($res.Count) items)"
            }

            $logMsg = "Executed snippet on collection `"$($script:activeCollection)`"$($countStr):"
            if ($Code.Contains(".add(") -or $Code.Contains(".insert(")) {
                $logMsg = "Document added to `"$($script:activeCollection)`":"
            }
            elseif ($Code.Contains(".update(")) {
                $logMsg = "Document updated in `"$($script:activeCollection)`":"
            }
            elseif ($Code.Contains(".delete(")) {
                $logMsg = "Document deleted from `"$($script:activeCollection)`":"
            }
            elseif ($Code.Contains(".get(")) {
                $logMsg = "Queried collection `"$($script:activeCollection)`"$($countStr):"
            }

            Log-ToConsole $logMsg $res $ms
            Refresh-DatabaseState
        } catch {
            $sw.Stop()
            $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            $txtStatusBadge.Text = "Error"
            $txtStatusBadge.Foreground = [System.Windows.Media.Brushes]::Crimson

            if ($null -ne $StatusLabel) {
                $StatusLabel.Text = "Error: $($_.Exception.Message)"
                $StatusLabel.Foreground = [System.Windows.Media.Brushes]::Crimson
            }
            Log-ToConsole "Error: $($_.Exception.Message)" $null $ms
        }
    }

    # -----------------------------------------------------------------------
    # Category Switching (Adding, Getting, Updating, Deleting, Custom)
    # -----------------------------------------------------------------------
    function Set-PlaygroundCategory([string]$Category) {
        $script:currentCategory = $Category
        $lblCategoryTitle.Text = $Category
        $coll = $script:activeCollection
        if (-not $coll) { $coll = "users" }

        # Style segmented nav pills (LiteDeploy Signature)
        $tabs = @($btnNavAdd, $btnNavGet, $btnNavUpdate, $btnNavDelete, $btnNavCustom)
        $names = @("Adding Data", "Getting Data", "Updating Data", "Deleting Data", "Custom PowerShell Script")

        for ($i = 0; $i -lt $tabs.Count; $i++) {
            $t = $tabs[$i]
            $isActive = ($names[$i] -eq $Category)
            if ($isActive) {
                $t.Background = $script:window.Resources["HeaderColor"]
                $t.Foreground = [System.Windows.Media.Brushes]::White
            } else {
                $t.Background = [System.Windows.Media.Brushes]::Transparent
                $t.Foreground = $script:window.Resources["MutedFgColor"]
            }
        }

        # Populate Cards with runnable PowerShell code snippets targeting $coll
        switch ($Category) {
            "Adding Data" {
                $card1.Visibility = [System.Windows.Visibility]::Visible
                $card2.Visibility = [System.Windows.Visibility]::Visible
                $card3.Visibility = [System.Windows.Visibility]::Collapsed

                $lblCard1Title.Text = "Add Document (Auto GUID Key)"
                $txtCodeCard1.Text = @"
`$db.collection('$coll').add(@{
    id     = 101
    name   = 'Bill Gates'
    role   = 'Founder'
    active = `$true
})
"@

                $lblCard2Title.Text = "Add with Custom Key (.set)"
                $txtCodeCard2.Text = @"
`$db.collection('$coll').doc('custom-item-key').set(@{
    id     = 202
    name   = 'Paul Allen'
    role   = 'Co-Founder'
    city   = 'Seattle'
})
"@
            }
            "Getting Data" {
                $card1.Visibility = [System.Windows.Visibility]::Visible
                $card2.Visibility = [System.Windows.Visibility]::Visible
                $card3.Visibility = [System.Windows.Visibility]::Visible

                $lblCard1Title.Text = "Get All Documents in Collection"
                $txtCodeCard1.Text = @"
`$db.collection('$coll').get()
"@

                $lblCard2Title.Text = "Get Document by Key or Criteria"
                $txtCodeCard2.Text = @"
`$db.collection('$coll').doc('custom-item-key').get()
"@

                $lblCard3Title.Text = "Filter with Where, OrderBy & Limit"
                $txtCodeCard3.Text = @"
`$db.collection('$coll')
    .where('id', '>=', 1)
    .orderBy('id', 'asc')
    .limit(10)
    .get()
"@
            }
            "Updating Data" {
                $card1.Visibility = [System.Windows.Visibility]::Visible
                $card2.Visibility = [System.Windows.Visibility]::Visible
                $card3.Visibility = [System.Windows.Visibility]::Collapsed

                $lblCard1Title.Text = "Update Document (Deep Merge)"
                $txtCodeCard1.Text = @"
`$db.collection('$coll').doc('custom-item-key').update(@{
    status = 'Verified'
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
})
"@

                $lblCard2Title.Text = "Set / Overwrite Entire Document"
                $txtCodeCard2.Text = @"
`$db.collection('$coll').doc('custom-item-key').set(@{
    id     = 202
    name   = 'Paul Allen'
    role   = 'Philanthropist'
    status = 'Active'
})
"@
            }
            "Deleting Data" {
                $card1.Visibility = [System.Windows.Visibility]::Visible
                $card2.Visibility = [System.Windows.Visibility]::Visible
                $card3.Visibility = [System.Windows.Visibility]::Collapsed

                $lblCard1Title.Text = "Delete Single Document by Key"
                $txtCodeCard1.Text = @"
`$db.collection('$coll').doc('custom-item-key').delete()
"@

                $lblCard2Title.Text = "Delete Entire Collection"
                $txtCodeCard2.Text = @"
`$db.collection('$coll').delete()
"@
            }
            "Custom PowerShell Script" {
                $card1.Visibility = [System.Windows.Visibility]::Visible
                $card2.Visibility = [System.Windows.Visibility]::Collapsed
                $card3.Visibility = [System.Windows.Visibility]::Collapsed

                $lblCard1Title.Text = "Interactive PowerShell Script Editor"
                $txtCodeCard1.Text = @"
# You have full access to `$db (PSLocalBase instance)
`$results = `$db.collection('$coll').get()
Write-Host "Found `$(`$results.Count) documents in $coll"
`$results
"@
            }
        }
    }

    # -----------------------------------------------------------------------
    # Initial Demo Seeding (Users, Products, Orders)
    # -----------------------------------------------------------------------
    function Seed-DefaultData {
        $null = $script:db.collection("users").delete()
        $null = $script:db.collection("products").delete()
        $null = $script:db.collection("orders").delete()

        $sampleUsers = @(
            @{ id = 1; name = "Bill"; age = 47; role = "Admin"; city = "Seattle" },
            @{ id = 2; name = "Paul"; age = 34; role = "Developer"; city = "Austin" },
            @{ id = 3; name = "Elena"; age = 29; role = "Designer"; city = "Madrid" }
        )
        foreach ($u in $sampleUsers) { $null = $script:db.collection("users").add($u) }

        $sampleProducts = @(
            @{ sku = "LAPTOP-01"; title = "ThinkPad X1 Carbon"; price = 1499.99; stock = 12 },
            @{ sku = "MOUSE-02"; title = "Logitech MX Master 3S"; price = 99.50; stock = 45 },
            @{ sku = "MONITOR-03"; title = "Dell UltraSharp 27 4K"; price = 549.00; stock = 8 }
        )
        foreach ($p in $sampleProducts) { $null = $script:db.collection("products").add($p) }

        $sampleOrders = @(
            @{ orderId = "ORD-1001"; userId = 1; total = 1599.49; status = "Shipped" },
            @{ orderId = "ORD-1002"; userId = 2; total = 99.50; status = "Delivered" }
        )
        foreach ($o in $sampleOrders) { $null = $script:db.collection("orders").add($o) }

        Log-ToConsole "Playground initialized with demo collections (users, products, orders)." @{
            users    = $sampleUsers.Count
            products = $sampleProducts.Count
            orders   = $sampleOrders.Count
        }
        Refresh-DatabaseState
        Set-PlaygroundCategory $script:currentCategory
    }

    # -----------------------------------------------------------------------
    # Event Wiring
    # -----------------------------------------------------------------------
    $btnToggleTheme.add_Click({
        Set-AppTheme (-not $script:isDarkMode)
    })

    $btnNavAdd.add_Click({ Set-PlaygroundCategory "Adding Data" })
    $btnNavGet.add_Click({ Set-PlaygroundCategory "Getting Data" })
    $btnNavUpdate.add_Click({ Set-PlaygroundCategory "Updating Data" })
    $btnNavDelete.add_Click({ Set-PlaygroundCategory "Deleting Data" })
    $btnNavCustom.add_Click({ Set-PlaygroundCategory "Custom PowerShell Script" })

    $btnRunCard1.add_Click({ Execute-CodeSnippet $txtCodeCard1.Text $lblCard1Status })
    $btnRunCard2.add_Click({ Execute-CodeSnippet $txtCodeCard2.Text $lblCard2Status })
    $btnRunCard3.add_Click({ Execute-CodeSnippet $txtCodeCard3.Text $lblCard3Status })

    $btnSeedDemo.add_Click({ Seed-DefaultData })

    $btnCheckpointWal.add_Click({
        $null = $script:db._ExecuteDirectSql("PRAGMA wal_checkpoint(TRUNCATE);")
        Log-ToConsole "WAL checkpoint executed cleanly (dirty pages synced to disk)."
        Refresh-DatabaseState
        [System.Windows.MessageBox]::Show("WAL checkpoint flushed cleanly to persistent disk!", "WAL Sync", "OK", "Information")
    })

    $btnResetDatabase.add_Click({
        $res = [System.Windows.MessageBox]::Show("Are you sure you want to purge all collections in $DbPath?", "Reset Database", "YesNo", "Warning")
        if ($res -eq "Yes") {
            $colls = @($script:db.listCollections())
            foreach ($c in $colls) { $null = $script:db.collection($c).delete() }
            Log-ToConsole "All collections were purged from database."
            Refresh-DatabaseState
            Set-PlaygroundCategory $script:currentCategory
        }
    })

    # Dropdown synchronization (Guaranteed visible text with DynamicDrivers styling)
    $cmbLeftCollection.add_SelectionChanged({
        if ($script:updatingDropdowns) { return }
        if ($cmbLeftCollection.SelectedItem) {
            $script:activeCollection = [string]$cmbLeftCollection.SelectedItem
            $script:updatingDropdowns = $true
            try { $cmbRightCollection.SelectedItem = $script:activeCollection } finally { $script:updatingDropdowns = $false }
            Load-CollectionDocuments $script:activeCollection
            Set-PlaygroundCategory $script:currentCategory
            Log-ToConsole "Switched active collection to `"$($script:activeCollection)`"."
        }
    })

    $cmbRightCollection.add_SelectionChanged({
        if ($script:updatingDropdowns) { return }
        if ($cmbRightCollection.SelectedItem) {
            $script:activeCollection = [string]$cmbRightCollection.SelectedItem
            $script:updatingDropdowns = $true
            try { $cmbLeftCollection.SelectedItem = $script:activeCollection } finally { $script:updatingDropdowns = $false }
            Load-CollectionDocuments $script:activeCollection
            Set-PlaygroundCategory $script:currentCategory
            Log-ToConsole "Switched active collection to `"$($script:activeCollection)`"."
        }
    })

    $btnRefreshTable.add_Click({
        Refresh-DatabaseState
        Log-ToConsole "Database state refreshed."
    })

    $btnClearCollection.add_Click({
        $null = $script:db.collection($script:activeCollection).delete()
        Log-ToConsole "Collection `"$($script:activeCollection)`" cleared."
        Refresh-DatabaseState
    })

    $btnDeleteDoc.add_Click({
        $sel = $dgDocuments.SelectedItem
        if ($null -ne $sel -and $sel.RawKey) {
            $null = $script:db.collection($script:activeCollection).doc($sel.RawKey).delete()
            Log-ToConsole "Deleted document `"$($sel.RawKey)`" from `"$($script:activeCollection)`"."
            Refresh-DatabaseState
        } else {
            [System.Windows.MessageBox]::Show("Please select a document from the table first.", "Selection Required", "OK", "Information")
        }
    })

    $dgDocuments.add_MouseDoubleClick({
        $sel = $dgDocuments.SelectedItem
        if ($null -ne $sel -and $null -ne $sel.DataObj) {
            Log-ToConsole "Inspected document `"$($sel.Key)`":" $sel.DataObj
        }
    })

    $txtKeySearch.add_TextChanged({
        Load-CollectionDocuments $script:activeCollection
    })

    $txtKeySearch.add_GotFocus({
        if ($txtKeySearch.Text -eq "Search key or text...") { $txtKeySearch.Text = "" }
    })

    $txtKeySearch.add_LostFocus({
        if (-not $txtKeySearch.Text.Trim()) {
            $txtKeySearch.Text = "Search key or text..."
            Load-CollectionDocuments $script:activeCollection
        }
    })

    $btnClearLogs.add_Click({
        $panelConsoleLogs.Children.Clear()
        Log-ToConsole "Console logs cleared."
    })

    $txtConsoleInput.add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
            $cmd = $txtConsoleInput.Text.Trim()
            $txtConsoleInput.Text = ""
            if ($cmd) {
                Execute-CodeSnippet $cmd $null
            }
        }
    })

    # -----------------------------------------------------------------------
    # Window Load & Activation
    # -----------------------------------------------------------------------
    $script:window.Add_ContentRendered({
        $script:window.Activate()
        $script:window.Topmost = $true
        $script:window.Topmost = $false
        $script:window.Focus()
    })

    $script:window.Add_Closed({
        if ($null -ne $script:db) {
            $script:db.close()
        }
    })

    # Detect Windows OS Dark Theme preference if not specified
    $initialDark = $StartInDark
    if (-not $initialDark) {
        try {
            $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            if (Test-Path $regKey) {
                $appsUseLightTheme = (Get-ItemProperty -Path $regKey -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue).AppsUseLightTheme
                if ($appsUseLightTheme -eq 0) {
                    $initialDark = $true
                }
            }
        } catch { }
    }

    Set-AppTheme $initialDark
    Set-PlaygroundCategory "Adding Data"

    $initialColls = @($script:db.listCollections())
    if ($initialColls.Count -eq 0 -or ($script:db.collection("users").count() -eq 0)) {
        Seed-DefaultData
    } else {
        Refresh-DatabaseState
    }

    Write-Host "Opening PSLocalBase Playground window (Theme: $(if ($initialDark) {'Dark'} else {'Light'}))..." -ForegroundColor Cyan
    $null = $script:window.ShowDialog()
}

# ---------------------------------------------------------------------------
# Main Execution Dispatcher (Guarantees Foreground STA Mode)
# ---------------------------------------------------------------------------
$isSta = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA

if ($isSta) {
    Start-PlaygroundApp -DbPath $DatabasePath -StartInDark:$DarkMode
} else {
    Write-Host "[PSLocalBase Playground] Starting in dedicated STA Runspace..." -ForegroundColor Cyan
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        $scriptPath = Join-Path $PSScriptRoot "Playground.ps1"
    }
    [void]$ps.AddScript((Get-Content -Path $scriptPath -Raw))
    [void]$ps.AddParameter('DatabasePath', $DatabasePath)
    if ($DarkMode) {
        [void]$ps.AddParameter('DarkMode', $true)
    }
    [void]$ps.Invoke()
    if ($ps.HadErrors) {
        $ps.Streams.Error | ForEach-Object { Write-Error $_ }
    }
    $ps.Dispose()
    $rs.Close()
    $rs.Dispose()
}
