Pod::Spec.new do |s|
  s.name             = 'quran_broadcast_sdk'
  s.version          = '0.1.0'
  s.summary          = 'Offline Quran broadcast ONNX Runtime bridge.'
  s.description      = <<-DESC
Native ONNX Runtime and keep-screen-on channels for quran_broadcast_sdk.
                       DESC
  s.homepage         = 'https://github.com/luobeibei0710/quran_offline_demo'
  s.license          = { :type => 'MIT' }
  s.author           = 'llvision'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'onnxruntime-objc', '1.22.0'
  s.platform = :ios, '15.5'
  s.static_framework = true
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
