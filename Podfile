# Uncomment this line to define a global platform for your project
platform :ios, '10.0'
# Uncomment this line if you're using Swift
use_frameworks!

plugin 'cocoapods-acknowledgements'

target 'HomeAssistant' do
  pod 'Alamofire', '4.7.3'
  pod 'AlamofireNetworkActivityIndicator', '2.3.0'
  pod 'AlamofireObjectMapper', '5.1.0'
  pod 'CPDAcknowledgements', '1.0.0'
  pod 'Crashlytics', '3.10.2'
  pod 'DeviceKit', '1.8'
  pod 'Eureka', :git => 'https://github.com/xmartlabs/Eureka.git', :branch => 'Swift-4.2'
  pod 'Fabric', '1.7.7'
  pod 'FontAwesomeKit/MaterialDesignIcons', :git => 'https://github.com/robbiet480/FontAwesomeKit.git', :branch => 'Material-Design-Icons'
  pod 'KeychainAccess', '3.1.1'
  pod 'MBProgressHUD', '1.1.0'
  pod 'ObjectMapper', '3.3.0'
  pod 'PromiseKit', '6.3.0'
  pod 'RealmSwift'
  pod 'SwiftGen', '5.3.0'
  pod 'SwiftLint', '0.25.1'

  target 'HomeAssistantTests' do
    inherit! :search_paths
  end
end

target 'Shared' do
  pod 'Alamofire', '4.7.3'
  pod 'AlamofireObjectMapper', '5.1.0'
  pod 'Crashlytics', '3.10.2'
  pod 'DeviceKit', '1.8'
  pod 'FontAwesomeKit/MaterialDesignIcons', :git => 'https://github.com/robbiet480/FontAwesomeKit.git', :branch => 'Material-Design-Icons'
  pod 'KeychainAccess', '3.1.1'
  pod 'ObjectMapper', '3.3.0'
  pod 'PromiseKit', '6.3.0'
  pod 'RealmSwift'
  target 'SharedTests' do
    inherit! :search_paths
  end
end


target 'HomeAssistantUITests' do

end

target 'APNSAttachmentService' do
  pod 'Alamofire', '4.7.3'
  pod 'AlamofireObjectMapper', '5.1.0'
  pod 'DeviceKit', '1.8'
  pod 'FontAwesomeKit/MaterialDesignIcons', :git => 'https://github.com/robbiet480/FontAwesomeKit.git', :branch => 'Material-Design-Icons'
  pod 'KeychainAccess', '3.1.1'
  pod 'ObjectMapper', '3.3.0'
  pod 'PromiseKit', '6.3.0'
  pod 'RealmSwift'
end

target 'MapNotificationContentExtension' do
  pod 'MBProgressHUD', '1.1.0'
  pod 'RealmSwift'
end


target 'NotificationContentExtension' do
  pod 'KeychainAccess', '3.1.1'
  pod 'MBProgressHUD', '1.1.0'
  pod 'RealmSwift'
end

target 'SiriIntents' do
  pod 'PromiseKit', '6.3.0'
end
