Quantcast iOS SDK
=================


Integrating Quantcast Measure for Mobile Apps
---------------------------------------------

### Project Setup ###

To integrate Quantcast’s SDK into your iOS app, you must use Xcode 4.5 or later. Please ensure you are using the latest version of Xcode before you begin the required code integration. The Quantcast SDK fully supports apps built for iOS 5 and later. With some modification, the Quantcast iOS SDK can also support iOS 4 and later.

Begin by cloning the Quantcast iOS SDK's git repository and initializing all of its submodules. Open the Terminal application in your Mac and issue the following commands:

``` bash
git clone https://github.com/quantcast/ios-measurement.git ./quantcast-ios-sdk
cd ./quantcast-ios-sdk/
git submodule update --init
```

Once you have downloaded the Quantcast iOS SDK's code, perform the following steps:

1.	Import the code into your project from the Quantcast-iOS-Measurement folder in the Quantcast repository you just created.
2.	Link the following iOS frameworks to your project if they are not already:
	*	`SystemConfiguration`
	*	`Foundation`
	*	`UIKit`
	*	`CoreTelephony`
	*	`CoreLocation`
3.	Weak-link (that is, make "optional") the following iOS frameworks to your project if they are not already:
	*	`AdSupport`
4.	Link the following libraries to your project, if they aren't already:
	*	`libz`
	*	`libsqlite3`

If you intend to support iOS 4.0 and later, you must perform the following steps:

5.	If you do not have the latest version of JSONKit integrated into your project, import the code from the JSONKit folder in the Quantcast github repository into your project.
6.	Add the following preprocessor macro definition to your project's precompiled header file (the file that ends with '.pch'):

	```objective-c
	#define QCMEASUREMENT_ENABLE_JSONKIT 1
	```

### Required Code Integration ###

The Quantcast iOS SDK has two points of required code integration. The first is a set of required calls to the SDK to indicate when the iOS app has been launched, paused (put into the background), resumed, and quit. The second provides users access to the Quantcast Measure Opt-Out dialog.

To implement the required set of SDK calls, perform the following steps:

1.	Import `QuantcastMeasurement.h` into your `UIApplication` delegate class
2.	In your `UIApplication` delegate's `application:didFinishLaunchingWithOptions:` method, place the following:

	```objective-c
	[[QuantcastMeasurement sharedInstance] beginMeasurementSessionWithAPIKey:@"<*Insert your API Key Here*>" labels:nil];
	```
		
	Replacing "<\*Insert your API Key Here\*>" with your Quantcast API Key, which can be generated in your Quantcast account homepage on [the Quantcast website](http://www.quantcast.com "Quantcast.com"). The labels parameter may be nil and is discussed in more detailed in the [Event Labels](#event-labels) section under Optional Code Integrations.
	
	The API Key is used as the basic reporting entity for Quantcast Measure. The same API Key can be used across multiple apps (i.e. AppName Free / AppName Paid) and/or app platforms (i.e. iOS / Android). For all apps under each unique API Key, Quantcast will report the aggregate audience among them all, and also identify/report on the individual app versions.
3.	In your `UIApplication` delegate's `applicationWillTerminate:` method, place the following:

	```objective-c
	[[QuantcastMeasurement sharedInstance] endMeasurementSessionWithLabels:nil];
	```
		
4.	In your `UIApplication` delegate's `applicationDidEnterBackground:` method, place the following:

	```objective-c
	[[QuantcastMeasurement sharedInstance] pauseSessionWithLabels:nil];
	```

5.	In your `UIApplication` delegate's `applicationWillEnterForeground:` method, place the following:

	```objective-c
	[[QuantcastMeasurement sharedInstance] resumeSessionWithLabels:nil];
	```

### Optional Code Integrations ###

#### User Opt-Out ####
You can give users the option to opt out of Quantcast Measure by providing access to the Quantcast Measure Opt-Out dialog. This should be accomplished with a button or a table view cell (if your options are based on a grouped table view) in your app's options view with the title "Measurement Options" or "Privacy". When a user taps the button you provide, call the Quantcast’s Opt-Out dialog using the following method:

```objective-c
[[QuantcastMeasurement sharedInstance] displayUserPrivacyDialogOver:currentViewController withDelegate:nil];
```
		
The `currentViewController` argument is the current view controller. The SDK needs to know this due to how the iOS SDK presents modal dialogs (see [Apple's documentation](http://developer.apple.com/library/ios/#documentation/uikit/reference/UIViewController_Class/Reference/Reference.html) for `presentViewController:animated:completion:`). The delegate is an optional parameter and is explained in the `QuantcastOptOutDelegate` protocol header.
	
Note: when a user opts out of Quantcast Measure, the SDK immediately stops transmitting information to or from the user's device and deletes any cached information that may have retained. Furthermore, when a user opts out of any single app on a device, the action affects all apps on the device that are integrated with Quantcast Measure.

#### Tracking App Events ####
Quantcast Measure can be used to measure audiences that engage in certain activities within your app. To log the occurrence of an app event or activity, call the following method:

```objective-c
[[QuantcastMeasurement sharedInstance] logEvent:theEventStr withLabels:nil];
```
`theEventStr` is the string that is associated with the event you are logging. Hierarchical information can be indicated by using a left-to-right notation with a period as a separator. For example, logging one event named "button.left" and another named "button.right" will create three reportable items in Quantcast Measure: "button.left", "button.right", and "button". There is no limit on the cardinality that this hierarchal scheme can create, though low-frequency events may not have an audience report due to the lack of a statistically significant population.

#### Event Labels ####
Most of Quantcast's public methods have an option to provide a label, or `nil` if no label is desired. A label is any arbitrary string that you want associated with an event. The label will create a second dimension in Quantcast Measure audience reporting. Normally, this dimension is a "user class" indicator. For example, you could use one of two labels in your app: one for users who have not purchased an app upgrade, and one for users who have purchased an upgrade.

While there is no specific constraint on the intended use of the label dimension, it is not recommended that you use it to indicate discrete events; in these cases, use the `logEvent:withLabels:` method described under [Tracking App Events](#tracking-app-events).

#### Geo-Location Measurement ####
To turn on geo-tracking, insert the following call into your `UIApplication` delegate's `application:didFinishLaunchingWithOptions:` method after you call either form of the `beginMeasurementSession:` methods:

```objective-c
[QuantcastMeasurement sharedInstance].geoLocationEnabled = YES;
```
Note that you should only enable geo-tracking if your app has some location-aware purpose.

The Quantcast iOS SDK will automatically pause geo-tracking while your app is in the background. This is done for both battery life and privacy considerations.

#### Combined Web/App Audiences ####
Quantcast Measure enables you to measure both your web and mobile app audiences, allowing you to understand the differences and similarities of your online and mobile app audiences, or even the audiences of your different apps. To enable this feature, you will need to provide a user identifier, which Quantcast will always anonymize with a 1-way hash before it is transmitted the user's device. This user identifier must also be provided for your website(s); please see Quantcast's web measurement documentation for instructions.

To provide Quantcast Measurem with the user identifier, call the following method:

```objective-c
[[QuantcastMeasurement sharedInstance] recordUserIdentifier:userIdentifierStr withLabels:nil];
```
Where `userIdentifierStr` is the user identifier that you use. The Quantcast iOS SDK will immediately 1-way hash the passed identifier, and return the hashed value for your reference. You do not need to take any action with the hashed value.

When starting a Quantcast Measure session, if you already know the user identifier (e.g., it was saved in the apps preferences) when the `UIApplication` delegate's `application:didFinishLaunchingWithOptions:` method is called, you may call the alternate version of the `beginMeasurementSessionWithAPIKey:labels:` method:

```objective-c
[[QuantcastMeasurement sharedInstance] beginMeasurementSessionWithAPIKey:@"<*Insert your API Key Here*>" userIdentifier:userIdentifierStrOrNil labels:nil];
```
Where `userIdentifierStrOrNil` is is the user identifier that you use, or `nil` if it is not available. Passing `nil` to this method's `userIdentifier:` argument has the same net effect as calling the `beginMeasurementSessionWithAPIKey:labels:` method.

*Important*: Use of this feature requires certain notice and disclosures to your website and mobile app users. Please see Quantcast's terms of service for more details.

#### SDK Customization ####

##### Logging and Debugging #####
You may enable logging within the Quantcast iOS SDK for debugging purposes. By default, logging is turned off. To enable logging, call the following method at any time, including prior to calling either of the `beginMeasurementSession:` methods:

```objective-c
[QuantcastMeasurement sharedInstance].enableLogging = YES;
```
You should not release an app with logging enabled.

##### Event Upload Frequency #####
The Quantcast iOS SDK will upload the events it collects to Quantcast's server periodically. Uploads that occur too often will drain the device's battery. Uploads that don't occur often enough will cause significant delays in Quantcast receiving the data needed for analysis and reporting. By default, these uploads occur when at least 100 events have been collected or when your application pauses (that is, it switched into the background). You can alter this default behavior by setting the `uploadEventCount` property. For example, if you wish to upload your app's events after 20 events have been collected, you would make the following call:

```objective-c
[QuantcastMeasurement sharedInstance].uploadEventCount = 20;
```

You may change this property multiple times throughout your app's execution.

### License ###
This Quantcast Measurement SDK is Copyright 2012 Quantcast Corp. This SDK is licensed under the Quantcast Mobile App Measurement Terms of Service, found at [the Quantcast website here](https://www.quantcast.com/learning-center/quantcast-terms/mobile-app-measurement-tos "Quantcast's Measurement SDK Terms of Service") (the "License"). You may not use this SDK unless (1) you sign up for an account at [Quantcast.com](https://www.quantcast.com "Quantcast.com") and click your agreement to the License and (2) are in compliance with the License. See the License for the specific language governing permissions and limitations under the License.
