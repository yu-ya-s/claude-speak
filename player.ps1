param(
  [string]$Dir = (Join-Path $env:TEMP "claude-speak")
)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:pid_file = Join-Path $Dir "player.pid"
Set-Content -Path $script:pid_file -Value $PID -Encoding ASCII

$script:durs = @{}        # チャンク番号 -> 実時間（秒）
$script:chars = @()       # チャンクごとの文字数
$script:lines = @()
$script:cur = 0
$script:waiting = $true
$script:paused = $false
$script:dragging = $false
$script:pending = 0.0

function Get-ChunkDuration([int]$i) {
  $dur_path = Join-Path $Dir ('{0:000}.dur' -f $i)
  if (-not (Test-Path $dur_path)) { return 0.0 }
  return [double]((Get-Content -Path $dur_path -Raw).Trim())
}

function Format-Time([double]$sec) {
  $s = [int][Math]::Floor($sec)
  return ('{0}:{1:00}' -f [int][Math]::Floor($s / 60), ($s % 60))
}

function Wav-Path([int]$i) { Join-Path $Dir ('{0:000}.mp3' -f $i) }

function Refresh-Chunks {
  $manifest = Join-Path $Dir "chunks.txt"
  if (Test-Path $manifest) {
    $lines = @(Get-Content -Path $manifest -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    $script:lines = $lines
    $script:chars = @($lines | ForEach-Object { $_.Length })
  }
  for ($i = 0; $i -lt $script:chars.Count; $i++) {
    if (-not $script:durs.ContainsKey($i) -and (Test-Path (Wav-Path $i))) {
      $script:durs[$i] = Get-ChunkDuration $i
    }
  }
}

# 先頭から連続して実時間が分かっているチャンク数
function Get-KnownCount {
  $n = 0
  while ($script:durs.ContainsKey($n)) { $n++ }
  return $n
}

function Get-Base([int]$upto) {
  $sum = 0.0
  for ($i = 0; $i -lt $upto; $i++) { if ($script:durs.ContainsKey($i)) { $sum += $script:durs[$i] } }
  return $sum
}

function Get-Total {
  $sum = 0.0
  for ($i = 0; $i -lt $script:chars.Count; $i++) {
    if ($script:durs.ContainsKey($i)) { $sum += $script:durs[$i] } else { $sum += $script:chars[$i] * 0.17 }
  }
  return $sum
}

function Get-GlobalPos {
  $base = Get-Base $script:cur
  if ($script:waiting) { return $base }
  return $base + $mp.Position.TotalSeconds
}

function Open-Chunk([int]$i, [double]$offset) {
  $script:cur = $i
  $script:pending = $offset
  $script:waiting = $false
  $mp.Open([Uri](Wav-Path $i))
  if ($script:paused) { $mp.Pause() } else { $mp.Play() }
}

function Seek-Global([double]$g) {
  $known = Get-KnownCount
  if ($known -eq 0) { return }
  if ($g -lt 0) { $g = 0 }
  $acc = 0.0
  for ($i = 0; $i -lt $known; $i++) {
    $d = $script:durs[$i]
    if ($g -lt $acc + $d -or $i -eq $known - 1) {
      $off = [Math]::Min($g - $acc, $d)
      Open-Chunk $i $off
      return
    }
    $acc += $d
  }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Claude 読み上げ" Width="400" SizeToContent="Height" Topmost="True"
        ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" FontFamily="Yu Gothic UI, Segoe UI">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#F01E1F24" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>
    <SolidColorBrush x:Key="Fg" Color="#F2F2F2" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>
    <SolidColorBrush x:Key="Muted" Color="#8A8F98" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>
    <SolidColorBrush x:Key="Accent" Color="#D97757" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>
    <SolidColorBrush x:Key="Track" Color="#3A3C44" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>
    <Style x:Key="IconButton" TargetType="Button" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="20" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#22FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#40FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MainButton" TargetType="Button" BasedOn="{StaticResource IconButton}" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
      <Setter Property="Width" Value="52"/>
      <Setter Property="Height" Value="52"/>
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="Foreground" Value="#1E1F24"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="26" Background="{StaticResource Accent}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E8886A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C2654A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SeekSlider" TargetType="Slider" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
      <Setter Property="Height" Value="20"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{StaticResource Track}" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track" VerticalAlignment="Center">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" IsHitTestVisible="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2" Background="{StaticResource Accent}"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" IsHitTestVisible="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="14" Height="14">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="{StaticResource Fg}" Stroke="{StaticResource Accent}" StrokeThickness="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Name="root" CornerRadius="14" Background="{StaticResource Bg}" Padding="20,16,20,14" Margin="8">
    <Border.Effect>
      <DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.45"/>
    </Border.Effect>
    <StackPanel>
      <DockPanel>
        <Button Name="stop_button" Style="{StaticResource IconButton}" DockPanel.Dock="Right" Width="28" Height="28" FontSize="11" Content="&#xE8BB;" ToolTip="停止して閉じる"/>
        <TextBlock Text="Claude 読み上げ" Foreground="{StaticResource Muted}" FontSize="11" VerticalAlignment="Center"/>
      </DockPanel>
      <TextBlock Name="line_text" Foreground="{StaticResource Fg}" FontSize="14" TextTrimming="CharacterEllipsis" Margin="0,8,0,10" Text=""/>
      <Slider Name="slider" Style="{StaticResource SeekSlider}" Minimum="0" Maximum="1" Margin="0,4,0,0"/>
      <DockPanel Margin="0,2,0,6">
        <TextBlock Name="sentence_text" DockPanel.Dock="Right" Foreground="{StaticResource Muted}" FontSize="11" Text="0/0"/>
        <TextBlock Name="time_text" Foreground="{StaticResource Muted}" FontSize="11" Text="0:00 / 0:00"/>
      </DockPanel>
      <Grid>
        <TextBlock Name="status_text" Foreground="{StaticResource Muted}" FontSize="11" VerticalAlignment="Center" Text=""/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
          <Button Name="back_button" Style="{StaticResource IconButton}" ToolTip="5秒戻る" Margin="0,0,12,0">
            <Grid Width="26" Height="26">
              <Grid><Grid.RenderTransform><ScaleTransform ScaleX="-1" CenterX="13"/></Grid.RenderTransform>
                <Path Stroke="{StaticResource Fg}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Data="M 20.8,18.5 A 9.5,9.5 0 1 1 20.3,6.9"/>
                <Path Fill="{StaticResource Fg}" Data="M 22.8,4.8 L 23.4,10.6 L 17.8,9.0 Z"/>
              </Grid>
              <TextBlock Text="5" Foreground="{StaticResource Fg}" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
            </Grid>
          </Button>
          <Button Name="pause_button" Style="{StaticResource MainButton}" Content="&#xE769;" ToolTip="一時停止"/>
          <Button Name="fwd_button" Style="{StaticResource IconButton}" ToolTip="5秒進む" Margin="12,0,0,0">
            <Grid Width="26" Height="26">
              <Grid>
                <Path Stroke="{StaticResource Fg}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Data="M 20.8,18.5 A 9.5,9.5 0 1 1 20.3,6.9"/>
                <Path Fill="{StaticResource Fg}" Data="M 22.8,4.8 L 23.4,10.6 L 17.8,9.0 Z"/>
              </Grid>
              <TextBlock Text="5" Foreground="{StaticResource Fg}" FontFamily="Segoe UI" FontWeight="SemiBold" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,1,0,0"/>
            </Grid>
          </Button>
        </StackPanel>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Parse($xaml)
$slider = $win.FindName('slider')
$time_text = $win.FindName('time_text')
$sentence_text = $win.FindName('sentence_text')
$status_text = $win.FindName('status_text')
$line_text = $win.FindName('line_text')
$pause_button = $win.FindName('pause_button')
$work = [Windows.SystemParameters]::WorkArea
$win.Left = $work.Right - $win.Width - 16
$win.Top = $work.Bottom - 190
$win.FindName('root').Add_MouseLeftButtonDown({ param($sender, $e) if (-not $script:dragging) { $win.DragMove() } })

$mp = New-Object System.Windows.Media.MediaPlayer
$mp.Add_MediaOpened({
  if ($script:pending -gt 0) {
    $mp.Position = [TimeSpan]::FromSeconds($script:pending)
    $script:pending = 0.0
  }
})
$mp.Add_MediaEnded({
  $script:cur++
  $script:waiting = $true
  $script:pending = 0.0
})

$win.FindName('back_button').Add_Click({ Seek-Global ((Get-GlobalPos) - 5) })
$win.FindName('fwd_button').Add_Click({ Seek-Global ((Get-GlobalPos) + 5) })
$pause_button.Add_Click({
  $script:paused = -not $script:paused
  if ($script:paused) { $pause_button.Content = [char]0xE768; $pause_button.ToolTip = '再生'; if (-not $script:waiting) { $mp.Pause() } }
  else { $pause_button.Content = [char]0xE769; $pause_button.ToolTip = '一時停止'; if (-not $script:waiting) { $mp.Play() } }
})
$win.FindName('stop_button').Add_Click({ $win.Close() })

# クリック位置・ドラッグ位置から値を決める（標準の当たり判定に頼らない）
function Set-SliderFromMouse($e) {
  $x = $e.GetPosition($slider).X
  $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $x / $slider.ActualWidth))
  $slider.Value = $slider.Minimum + ($slider.Maximum - $slider.Minimum) * $ratio
}
$slider.Add_PreviewMouseLeftButtonDown({
  param($sender, $e)
  $script:dragging = $true
  Set-SliderFromMouse $e
  $slider.CaptureMouse() | Out-Null
  $e.Handled = $true
})
$slider.Add_PreviewMouseMove({
  param($sender, $e)
  if ($script:dragging) { Set-SliderFromMouse $e }
})
$slider.Add_PreviewMouseLeftButtonUp({
  param($sender, $e)
  if (-not $script:dragging) { return }
  Set-SliderFromMouse $e
  $slider.ReleaseMouseCapture()
  $script:dragging = $false
  Seek-Global $slider.Value
  $e.Handled = $true
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
  Refresh-Chunks
  $count = $script:chars.Count
  $done = Test-Path (Join-Path $Dir "done")
  if ($script:waiting) {
    if ($script:cur -lt $count -and (Test-Path (Wav-Path $script:cur))) {
      Open-Chunk $script:cur 0.0
    } elseif ($done) {
      $win.Close(); return
    } else {
      $status_text.Text = '生成中…'
    }
  } else {
    $status_text.Text = ''
  }
  $total = Get-Total
  $pos = Get-GlobalPos
  if ($pos -gt $total) { $total = $pos }
  if (-not $script:dragging) {
    $slider.Maximum = [Math]::Max($total, 1)
    $slider.Value = $pos
  }
  $shown = if ($script:dragging) { $slider.Value } else { $pos }
  $time_text.Text = '{0} / {1}' -f (Format-Time $shown), (Format-Time $total)
  $sentence_text.Text = '{0} / {1}' -f ([Math]::Min($script:cur + 1, $count)), $count
  $idx = [Math]::Min($script:cur, $count - 1)
  if ($idx -ge 0) { $line_text.Text = $script:lines[$idx] }
})

$win.Add_Closed({
  $timer.Stop()
  $mp.Close()
  Remove-Item -Path $script:pid_file -ErrorAction SilentlyContinue
})

Refresh-Chunks
$timer.Start()
$win.ShowDialog() | Out-Null
