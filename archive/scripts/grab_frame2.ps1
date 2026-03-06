# Camera capture via inline C# using Windows.Media.Capture WinRT

Add-Type -ReferencedAssemblies @(
    'System.Runtime',
    'System.Runtime.InteropServices.WindowsRuntime',
    (Join-Path $env:windir 'System32\WinMetadata\Windows.Foundation.winmd'),
    (Join-Path $env:windir 'System32\WinMetadata\Windows.Devices.winmd'),
    (Join-Path $env:windir 'System32\WinMetadata\Windows.Media.winmd'),
    (Join-Path $env:windir 'System32\WinMetadata\Windows.Storage.winmd')
) -Language CSharp -TypeDefinition @'
using System;
using System.Threading.Tasks;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Devices.Enumeration;
using Windows.Storage;

public class CamCapture {
    public static async Task<string> Capture(string outputPath, string preferName) {
        var devices = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture);
        DeviceInformation cam = null;
        foreach (var d in devices) {
            if (d.Name.Contains(preferName)) { cam = d; break; }
        }
        if (cam == null && devices.Count > 0) cam = devices[0];
        if (cam == null) return "No cameras found";

        var settings = new MediaCaptureInitializationSettings { VideoDeviceId = cam.Id };
        var mc = new MediaCapture();
        await mc.InitializeAsync(settings);

        var folder = await StorageFolder.GetFolderFromPathAsync(
            System.IO.Path.GetDirectoryName(outputPath));
        var file = await folder.CreateFileAsync(
            System.IO.Path.GetFileName(outputPath),
            CreationCollisionOption.ReplaceExisting);

        await mc.CapturePhotoToStorageFileAsync(
            ImageEncodingProperties.CreateJpeg(), file);
        mc.Dispose();
        return "Captured: " + cam.Name;
    }
}
'@ 2>&1

if ($?) {
    $result = [CamCapture]::Capture("C:\Claude\hmi430\frame.jpg", "Global Shutter").GetAwaiter().GetResult()
    Write-Host $result
    if (Test-Path "C:\Claude\hmi430\frame.jpg") {
        Write-Host "Size: $((Get-Item 'C:\Claude\hmi430\frame.jpg').Length) bytes"
    }
} else {
    Write-Host "Compilation failed"
}
