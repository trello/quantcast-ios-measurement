//
// Copyright (c) 2012, Quantcast Corp.
// This software is licensed under the Quantcast Mobile API Beta Evaluation Agreement and may not be used except as permitted thereunder or copied, modified, or distributed in any case.
//

#ifndef __has_feature
#define __has_feature(x) 0
#endif
#ifndef __has_extension
#define __has_extension __has_feature // Compatibility with pre-3.0 compilers.
#endif

#if __has_feature(objc_arc) && __clang_major__ >= 3
#error "Quantcast Measurement is not designed to be used with ARC. Please add '-fno-objc-arc' to this file's compiler flags"
#endif // __has_feature(objc_arc)

#import <AdSupport/AdSupport.h>
#import "QuantcastMeasurement.h"
#import "QuantcastParameters.h"
#import "QuantcastDataManager.h"
#import "QuantcastEvent.h"
#import "QuantcastUtils.h"
#import "QuantcastPolicy.h"
#import "QuantcastOptOutViewController.h"

QuantcastMeasurement* gSharedInstance = nil;


@interface QuantcastMeasurement ()
@property (retain,nonatomic) NSString* currentSessionID;
@property (retain,nonatomic) NSString* publisherCode;
@property (retain,nonatomic) NSNumber* appleAppID;
@property (retain,nonatomic) CLLocationManager* locationManager;
@property (retain,nonatomic) CLGeocoder* geocoder;
@property (readonly,nonatomic) BOOL isMeasurementActive;
@property (retain,nonatomic) NSDate* sessionPauseStartTime;
@property (retain,nonatomic) NSString* geoCountry;
@property (retain,nonatomic) NSString* geoProvince;
@property (retain,nonatomic) NSString* geoCity;
@property (readonly,nonatomic) BOOL advertisingTrackingEnabled;

+(NSString*)generateSessionID;
+(BOOL)isOptedOutStatus;

-(NSString*)appIdentifierWithUserAdvertisingPreference:(BOOL)inAdvertisingTrackingEnabled;
-(BOOL)hasUserAdvertisingPrefChangeWithCurrentPref:(BOOL)inCurrentPref;

-(void)enableDataUploading;
-(void)recordEvent:(QuantcastEvent*)inEvent;
-(void)logUploadLatency:(NSUInteger)inLatencyMilliseconds forUploadId:(NSString*)inUploadID;
-(void)setOptOutStatus:(BOOL)inOptOutStatus;
-(void)startNewSessionAndGenerateEventWithReason:(NSString*)inReason withLabels:(NSString*)inLabelsOrNil;
-(void)startNewSessionIfUsersAdPrefChanged;

-(NSString*)setUserIdentifier:(NSString*)inUserIdentifierOrNil;

-(void)startGeoLocationMeasurement;
-(void)stopGeoLocationMeasurement;
-(void)pauseGeoLocationMeasurement;
-(void)resumeGeoLocationMeasurment;
-(void)generateGeoEventWithCurrentLocation;

-(void)logNetworkReachability;
-(BOOL)startReachabilityNotifier;
-(void)stopReachabilityNotifier;

@end

@implementation QuantcastMeasurement
@synthesize locationManager;
@synthesize geocoder;
@synthesize sessionPauseStartTime;

+(QuantcastMeasurement*)sharedInstance {

    @synchronized( [QuantcastMeasurement class] ) {
        if ( nil == gSharedInstance ) {
            
            gSharedInstance = [[QuantcastMeasurement alloc] init];
            
        }
    }
    
    return gSharedInstance;
}

-(id)init {
    self = [super init];
    if (self) {
        self.enableLogging = NO;
        
        // the first thing to do is determine user opt-out status, as that will guide everything else.
        
        _isOptedOut = [QuantcastMeasurement isOptedOutStatus];
        
        _geoLocationEnabled = NO;
        
    }
    
    return self;
}

-(void)dealloc {
    
    [self stopReachabilityNotifier];
    self.geoLocationEnabled = NO;
    
    [geocoder release];
    [locationManager release];
    [sessionPauseStartTime release];
    [publisherCode release];
    [appleAppID release];
    
    [_dataManager release];
    [_hashedUserId release];
    
    
    [super dealloc];
}

-(BOOL)advertisingTrackingEnabled {
    BOOL userAdvertisingPreference = YES;
    
    Class adManagerClass = NSClassFromString(@"ASIdentifierManager");
    
    if ( nil != adManagerClass ) {
        
        ASIdentifierManager* adPrefManager = [adManagerClass sharedManager];
        
        userAdvertisingPreference = adPrefManager.advertisingTrackingEnabled;
    }

    return userAdvertisingPreference;
}

#pragma mark - Device Identifier
-(NSString*)deviceIdentifier {
    
    if ( self.isOptedOut ) {
        return nil;
    }
    
    NSString* udidStr = nil;
    
    Class adManagerClass = NSClassFromString(@"ASIdentifierManager");
    
    if ( nil != adManagerClass ) {
        
        ASIdentifierManager* manager = [adManagerClass sharedManager];
        
        if ( manager.advertisingTrackingEnabled) {
            NSUUID* uuid = manager.advertisingIdentifier;
            
            if ( nil != uuid ) {
                udidStr = [uuid UUIDString];
            }
        }
    }
    else if ([[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] != NSOrderedAscending) {
        NSLog(@"QC Measurement: ERROR - This app is running on iOS 6 or later and is not properly linked with the AdSupport.framework");
    }

    return udidStr;

}

-(NSString*)appIdentifier {
    return [self appIdentifierWithUserAdvertisingPreference:self.advertisingTrackingEnabled];
}

-(NSString*)appIdentifierWithUserAdvertisingPreference:(BOOL)inAdvertisingTrackingEnabled {
    // this method is factored out for testability reasons
    
    if ( self.isOptedOut ) {
        return nil;
    }
   
    // first, check if one exists and use it contents
    
    NSString* cacheDir = [QuantcastUtils quantcastCacheDirectoryPathCreatingIfNeeded];
    
    if ( nil == cacheDir) {
        return @"";
    }
    
    NSError* writeError = nil;

    NSString* identFile = [cacheDir stringByAppendingPathComponent:QCMEASUREMENT_IDENTIFIER_FILENAME];
    
    // first thing is to determine if apple's ad ID pref has changed. If so, create a new app id.
    

    BOOL adIdPrefHasChanged = [self hasUserAdvertisingPrefChangeWithCurrentPref:inAdvertisingTrackingEnabled];
    
    
    if ( [[NSFileManager defaultManager] fileExistsAtPath:identFile] && !adIdPrefHasChanged ) {
        NSError* readError = nil;
        
        NSString* idStr = [NSString stringWithContentsOfFile:identFile encoding:NSUTF8StringEncoding error:&readError];
        
        if ( nil != readError && self.enableLogging ) {
            NSLog(@"QC Measurement: Error reading app specific identifier file = %@ ", readError );
        }
        
        // make sure string is of proper size before using it. Expecting something like "68753A44-4D6F-1226-9C60-0050E4C00067"
        
        if ( [idStr length] == 36 ) {
            return idStr;
        }
    }
    
    // a condition exists where a new app install ID needs to be created. create a new ID
    
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef uuidStr = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    
    NSString* newIdStr = [NSString stringWithString:(NSString *)uuidStr ];
    
    CFRelease(uuidStr);
    CFRelease(uuid);
    
    writeError = nil;
    
    [newIdStr writeToFile:identFile atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    
    if ( self.enableLogging ) {
        if ( nil != writeError ) {
            NSLog(@"QC Measurement: Error when writing app specific identifier = %@", writeError);
        }
        else {
            NSLog(@"QC Measurement: Create new app identifier '%@' and wrote to file '%@'", newIdStr, identFile );
        }
    }
    
    return newIdStr;
}


-(BOOL)hasUserAdvertisingPrefChangeWithCurrentPref:(BOOL)inCurrentPref {

    NSString* cacheDir = [QuantcastUtils quantcastCacheDirectoryPathCreatingIfNeeded];
    NSString* adIdPrefFile = [cacheDir stringByAppendingPathComponent:QCMEASUREMENT_ADIDPREF_FILENAME];

    BOOL adIdPrefHasChanged = NO;
    NSNumber* adIdPrefValue = [NSNumber numberWithBool:inCurrentPref];
    NSString* currentAdIdPref = [adIdPrefValue stringValue];
    NSError* writeError = nil;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:adIdPrefFile] ) {
        NSError* readError = nil;
        
        NSString* savedAdIdPref = [NSString stringWithContentsOfFile:adIdPrefFile encoding:NSUTF8StringEncoding error:&readError];
        
        
        if ( [savedAdIdPref compare:currentAdIdPref] != NSOrderedSame ) {
            adIdPrefHasChanged = YES;
            
            writeError = nil;
            
            [currentAdIdPref writeToFile:adIdPrefFile atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
            
            if ( nil != writeError && self.enableLogging ) {
                NSLog(@"QC Measurement: Error writing user's ad tracking preference to file = %@", writeError );
            }
        }
    }
    else {
        writeError = nil;
        
        [currentAdIdPref writeToFile:adIdPrefFile atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        
        if ( nil != writeError && self.enableLogging ) {
            NSLog(@"QC Measurement: Error writing user's ad tracking preference to file = %@", writeError );
        }
    }
    
    return adIdPrefHasChanged;

}

#pragma mark - Event Recording

-(void)recordEvent:(QuantcastEvent*)inEvent {
    
    [_dataManager recordEvent:inEvent];
}

-(void)enableDataUploading {
    // this method is factored out primarily for unit testing reasons
    
    [_dataManager enableDataUploadingWithReachability:self];

}

#pragma mark - Session Management
@synthesize currentSessionID;
@synthesize publisherCode;
@synthesize appleAppID;

+(NSString*)generateSessionID {
    CFUUIDRef sessionUUID = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef sessionIDStr = CFUUIDCreateString(kCFAllocatorDefault, sessionUUID);
    
    NSString* sessionID = [NSString stringWithString:(NSString*)sessionIDStr];
    
    CFRelease(sessionIDStr);
    CFRelease(sessionUUID);
    
    return sessionID;
}

-(BOOL)isMeasurementActive {
    return nil != self.currentSessionID;
}

-(void)startNewSessionAndGenerateEventWithReason:(NSString*)inReason withLabels:(NSString*)inLabelsOrNil {
    
    self.currentSessionID = [QuantcastMeasurement generateSessionID];
    
    if ( nil != _dataManager.policy ) {
        [_dataManager.policy downloadLatestPolicyWithReachability:self];
    }

    QuantcastEvent* e = [QuantcastEvent openSessionEventWithClientUserHash:_hashedUserId
                                                          newSessionReason:inReason
                                                             networkStatus:[self currentReachabilityStatus]
                                                                 sessionID:self.currentSessionID
                                                             publisherCode:self.publisherCode
                                                                appleAppId:self.appleAppID
                                                          deviceIdentifier:self.deviceIdentifier
                                                             appIdentifier:self.appIdentifier
                                                           enforcingPolicy:_dataManager.policy
                                                               eventLabels:inLabelsOrNil];
    
    
    [self recordEvent:e];
    
    [self generateGeoEventWithCurrentLocation];
}


-(void)beginMeasurementSession:(NSString*)inPublisherCode withAppleAppId:(NSUInteger)inAppleAppId labels:(NSString*)inLabelsOrNil {
    
    self.publisherCode = inPublisherCode;
    
    if ( inAppleAppId > 0 ) {
        self.appleAppID = [NSNumber numberWithUnsignedInteger:inAppleAppId];
    }
 
    if ( !self.isOptedOut ) {
        [self startReachabilityNotifier];
        
        
        if (nil == _dataManager) {
            QuantcastPolicy* policy = [QuantcastPolicy policyWithPublisherCode:inPublisherCode networkReachability:self];
            
            if ( nil == policy ) {
                // policy wasn't able to be built. Stop reachability and bail, thus not activating measurement.
                [self stopReachabilityNotifier];
                
                if (self.enableLogging) {
                    NSLog(@"QC Measurement: Unable to activate measurement due to policy object being nil.");
                }
                return;
            }
            
            _dataManager = [[QuantcastDataManager alloc] initWithOptOut:self.isOptedOut policy:policy];
            _dataManager.enableLogging = self.enableLogging;

        }

        [self enableDataUploading];
        

        [self startNewSessionAndGenerateEventWithReason:QCPARAMETER_REASONTYPE_LAUNCH withLabels:inLabelsOrNil];
                
        if (self.enableLogging) {
            NSLog(@"QC Measurement: Using '%@' for upload server.",QCMEASUREMENT_UPLOAD_URL);
        }
    }
    
}

-(NSString*)beginMeasurementSession:(NSString*)inPublisherCode withUserIdentifier:(NSString*)inUserIdentifierOrNil appleAppId:(NSUInteger)inAppleAppId labels:(NSString*)inLabelsOrNil {
    
    NSString* hashedUserID = [self setUserIdentifier:inUserIdentifierOrNil];
    
    [self beginMeasurementSession:inPublisherCode withAppleAppId:inAppleAppId labels:inLabelsOrNil];
    
    return hashedUserID;
}

-(void)endMeasurementSessionWithLabels:(NSString*)inLabelsOrNil {
    if ( !self.isOptedOut  ) {
        
        if ( self.isMeasurementActive ) {
            QuantcastEvent* e = [QuantcastEvent closeSessionEventWithSessionID:self.currentSessionID enforcingPolicy:_dataManager.policy eventLabels:inLabelsOrNil];
        
            [self recordEvent:e];
            
            [self stopGeoLocationMeasurement];
            [self stopReachabilityNotifier];
            
            self.currentSessionID = nil;
        }
        else {
            NSLog(@"QC Measurement: endMeasurementSessionWithLabels: was called without first calling beginMeasurementSession:");
        }
    }
}
-(void)pauseSessionWithLabels:(NSString*)inLabelsOrNil {
    
    if ( !self.isOptedOut ) {
        if ( self.isMeasurementActive ) {
            
            QuantcastEvent* e = [QuantcastEvent pauseSessionEventWithSessionID:self.currentSessionID enforcingPolicy:_dataManager.policy eventLabels:inLabelsOrNil];
            
            [self recordEvent:e];
            
            self.sessionPauseStartTime = [NSDate date];
            
            [self pauseGeoLocationMeasurement];
            [self stopReachabilityNotifier];
            [_dataManager initiateDataUpload];
        }
        else {
            NSLog(@"QC Measurement: pauseSessionWithLabels: was called without first calling beginMeasurementSession:");
        }
    }
}
-(void)resumeSessionWithLabels:(NSString*)inLabelsOrNil {
    // first, always check to see if iopt-out status has changed while the app was paused:
    
    [self setOptOutStatus:[QuantcastMeasurement isOptedOutStatus]];

    if ( !self.isOptedOut ) {
        
        if ( self.isMeasurementActive ) {
            QuantcastEvent* e = [QuantcastEvent resumeSessionEventWithSessionID:self.currentSessionID enforcingPolicy:_dataManager.policy eventLabels:inLabelsOrNil];
        
            [self recordEvent:e];
            
            [self startNewSessionIfUsersAdPrefChanged];
            
            [self startReachabilityNotifier];
            [self resumeGeoLocationMeasurment];
            
            if ( self.sessionPauseStartTime != nil ) {
                NSDate* curTime = [NSDate date];
                
                if ( [curTime timeIntervalSinceDate:self.sessionPauseStartTime] > _dataManager.policy.sessionPauseTimeoutSeconds ) {
                    
                    [self startNewSessionAndGenerateEventWithReason:QCPARAMETER_REASONTYPE_RESUME withLabels:inLabelsOrNil];
                    
                    if (self.enableLogging) {
                        NSLog(@"QC Measurement: Starting new session after app being paused for extend period of time.");
                    }
                }

                self.sessionPauseStartTime = nil;
            }
        
        }
        else {
            NSLog(@"QC Measurement: resumeSessionWithLabels: was called without first calling beginMeasurementSession:");
        }
    }
}

-(void)startNewSessionIfUsersAdPrefChanged {    
    if ( [self hasUserAdvertisingPrefChangeWithCurrentPref:self.advertisingTrackingEnabled]) {
        if (self.enableLogging) {
            NSLog(@"QC Measurement: The user has changed their advertising tracking preference. Adjusting identifiers and starting a new session.");
        }
        
        [self startNewSessionAndGenerateEventWithReason:QCPARAMETER_REASONTYPE_ADPREFCHANGE withLabels:nil];
    }
}

#pragma mark - Network Reachability

static void QuantcastReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info)
{
#pragma unused (target, flags)
    if ( info == NULL ) {
        NSLog(@"QC Measurement: info was NULL in QuantcastReachabilityCallback");
        return;
    }
    if ( ![(NSObject*) info isKindOfClass: [QuantcastMeasurement class]] ) {
        NSLog(@"QC Measurement: info was wrong class in QuantcastReachabilityCallback");
        return;
    }

    NSAutoreleasePool* myPool = [[NSAutoreleasePool alloc] init];
    
    QuantcastMeasurement* qcMeasurement = (QuantcastMeasurement*) info;
    
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kQuantcastNetworkReachabilityChangedNotification object:qcMeasurement];

    
    [qcMeasurement logNetworkReachability];
    
    [myPool release];
}


-(void)logNetworkReachability {
    if ( !self.isOptedOut && self.isMeasurementActive ) {
                
        
        QuantcastEvent* e = [QuantcastEvent networkReachabilityEventWithNetworkStatus:[self currentReachabilityStatus]
                                                                        withSessionID:self.currentSessionID
                                                                      enforcingPolicy:_dataManager.policy];
        
        [self recordEvent:e];
    }
}


-(BOOL)startReachabilityNotifier
{
    BOOL retVal = NO;
    
    if ( NULL == _reachability ) {
        SCNetworkReachabilityContext    context = {0, self, NULL, NULL, NULL};

        NSURL* url = [NSURL URLWithString:QCMEASUREMENT_UPLOAD_URL];
        
        _reachability = SCNetworkReachabilityCreateWithName(NULL, [[url host] UTF8String]);
        

        if(SCNetworkReachabilitySetCallback(_reachability, QuantcastReachabilityCallback, &context))
        {
            if(SCNetworkReachabilityScheduleWithRunLoop(_reachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode))
            {
                retVal = YES;
            }
        }
    }
    return retVal;
}

-(void)stopReachabilityNotifier
{
    if(NULL != _reachability )
    {
        SCNetworkReachabilityUnscheduleFromRunLoop(_reachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        
        CFRelease(_reachability);
        
        _reachability = NULL;
    }
}

-(QuantcastNetworkStatus)currentReachabilityStatus
{
    if ( NULL == _reachability ) {
        return NotReachable;
    }

    QuantcastNetworkStatus retVal = NotReachable;
    SCNetworkReachabilityFlags flags;
    if (SCNetworkReachabilityGetFlags(_reachability, &flags))
    {
        if ((flags & kSCNetworkReachabilityFlagsReachable) == 0)
        {
            // if target host is not reachable
            return NotReachable;
        }

        if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0)
        {
            // if target host is reachable and no connection is required
            //  then we'll assume (for now) that your on Wi-Fi
            retVal = ReachableViaWiFi;
        }


        if ((((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) ||
             (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0))
        {
            // ... and the connection is on-demand (or on-traffic) if the
            //     calling application is using the CFSocketStream or higher APIs
            
            if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0)
            {
                // ... and no [user] intervention is needed
                retVal = ReachableViaWiFi;
            }
        }

        if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN)
        {
            // ... but WWAN connections are OK if the calling application
            //     is using the CFNetwork (CFSocketStream?) APIs.
            retVal = ReachableViaWWAN;
        }
    }
    return retVal;
}

#pragma mark - Measurement and Analytics

-(NSString*)setUserIdentifier:(NSString*)inUserIdentifierOrNil {
    
    if (self.isOptedOut) {
        return nil;
    }

    
    if ( nil == inUserIdentifierOrNil ) {
        // the "log out" semantics
        [_hashedUserId release];
        _hashedUserId = nil;
                
        return nil;
    }

    NSString* hashedUserID = [QuantcastUtils quantcastHash:inUserIdentifierOrNil];
        
    if ( nil != _hashedUserId ) {
        [_hashedUserId release];
        _hashedUserId = nil;
    }
    _hashedUserId = [hashedUserID retain];

    return hashedUserID;
}

-(NSString*)recordUserIdentifier:(NSString*)inUserIdentifierOrNil withLabels:(NSString*)inLabelsOrNil {
    
    if (self.isOptedOut) {
        return nil;
    }
    
    if ( !self.isMeasurementActive ) {
        NSLog(@"QC Measurement: recordUserIdentifier:withLabels: was called without first calling beginMeasurementSession:");
        return nil;
    }
    
    // save current hashed user ID in order to detect session changes
    NSString* originalHashedUserId = nil;
    if ( _hashedUserId != nil ) {
        originalHashedUserId = [[_hashedUserId copy] autorelease];
    }
    
    NSString* hashedUserId = [self setUserIdentifier:inUserIdentifierOrNil];
    
    if ( ( originalHashedUserId == nil && hashedUserId != nil ) || ( originalHashedUserId != nil && [originalHashedUserId compare:hashedUserId] != NSOrderedSame ) ) {
        [self startNewSessionAndGenerateEventWithReason:QCPARAMETER_REASONTYPE_USERHASH withLabels:inLabelsOrNil];
    }

    return hashedUserId;
}

-(void)logEvent:(NSString*)inEventName withLabels:(NSString*)inLabelsOrNil {
    
    if ( !self.isOptedOut ) {
        if (self.isMeasurementActive) {
            QuantcastEvent* e = [QuantcastEvent logEventEventWithEventName:inEventName
                                                               eventLabels:inLabelsOrNil
                                                                 sessionID:self.currentSessionID
                                                           enforcingPolicy:_dataManager.policy];
                                 
            [self recordEvent:e];
        }
        else {
            NSLog(@"QC Measurement: logEvent:withLabels: was called without first calling beginMeasurementSession:");
        }
    }
}

-(void)logUploadLatency:(NSUInteger)inLatencyMilliseconds forUploadId:(NSString*)inUploadID {
    if ( !self.isOptedOut && self.isMeasurementActive ) {
        QuantcastEvent* e = [QuantcastEvent logUploadLatency:inLatencyMilliseconds
                                                 forUploadId:inUploadID
                                               withSessionID:self.currentSessionID
                                             enforcingPolicy:_dataManager.policy];
        
        [self recordEvent:e];
    }
}



#pragma mark - Geo Location Handling
@synthesize geoCountry, geoProvince, geoCity;

-(BOOL)geoLocationEnabled {
    return _geoLocationEnabled;
}

-(void)setGeoLocationEnabled:(BOOL)inGeoLocationEnabled {
    
    Class geoCoderClass = NSClassFromString(@"CLGeocoder");
    
    if ( nil != geoCoderClass ) {
        CLAuthorizationStatus authStatus = [CLLocationManager authorizationStatus];
        
        _geoLocationEnabled = inGeoLocationEnabled && ( authStatus == kCLAuthorizationStatusNotDetermined || authStatus == kCLAuthorizationStatusAuthorized );
        
        if (_geoLocationEnabled) {
            [self startGeoLocationMeasurement];
        }
        else {
            [self stopGeoLocationMeasurement];
        }
        
    }
    
}

-(void)startGeoLocationMeasurement {
    self.geoCountry = nil;
    self.geoProvince = nil;
    self.geoCity = nil;
    
    if ( !self.isOptedOut && self.geoLocationEnabled ) {
        if (self.enableLogging) {
            NSLog(@"QC Measurement: Enabling geo-location measurement.");
        }
        // turn it on
        if (nil == self.locationManager) {
            self.locationManager = [[[CLLocationManager alloc] init] autorelease];
            self.locationManager.desiredAccuracy = kCLLocationAccuracyKilometer;
            self.locationManager.delegate = self;
        }
        
        [self.locationManager startMonitoringSignificantLocationChanges];
        
    }
}

-(void)stopGeoLocationMeasurement {
    if (self.enableLogging) {
        NSLog(@"QC Measurement: Disabling geo-location measurement.");
    }
    self.geoCountry = nil;
    self.geoProvince = nil;
    self.geoCity = nil;
    
    [self.locationManager stopMonitoringSignificantLocationChanges];
}

-(void)pauseGeoLocationMeasurement {
    if ( self.geoLocationEnabled && nil != self.locationManager ) {
        [self.locationManager stopMonitoringSignificantLocationChanges];
    }
}

-(void)resumeGeoLocationMeasurment {
    if ( self.geoLocationEnabled && nil != self.locationManager ) {
        [self.locationManager startMonitoringSignificantLocationChanges];
    }
}

- (void)locationManager:(CLLocationManager *)manager 
    didUpdateToLocation:(CLLocation *)newLocation
           fromLocation:(CLLocation *)oldLocation 
{
    
    if (nil == self.geocoder ) {
        self.geocoder = [[[CLGeocoder alloc] init] autorelease];
    }
    
    
    if ( !self.geocoder.geocoding ) {
        [self.geocoder reverseGeocodeLocation:newLocation 
                            completionHandler:^(NSArray* inPlacemarkList, NSError* inError) {
                                if ( nil == inError && [inPlacemarkList count] > 0 && !self.isOptedOut && self.isMeasurementActive ) {
                                    CLPlacemark* placemark = (CLPlacemark*)[inPlacemarkList objectAtIndex:0];
                                    
                                    self.geoCountry = [placemark country];
                                    self.geoProvince = [placemark administrativeArea];
                                    self.geoCity = [placemark locality];
                                    
                                    [self generateGeoEventWithCurrentLocation];
                                }
                                else {
                                    self.geoCountry = nil;
                                    self.geoProvince = nil;
                                    self.geoCity = nil;
                                   
                                }
                                
                            } ];
        
    
    
    }
    
}

-(void)generateGeoEventWithCurrentLocation {
    if (!self.isOptedOut && self.geoLocationEnabled) {
        
        if ( nil != self.geoCountry || nil != self.geoProvince || nil != self.geoCity ) {
            
            
            QuantcastEvent* e = [QuantcastEvent geolocationEventWithCountry:self.geoCountry
                                                                   province:self.geoProvince
                                                                       city:self.geoCity
                                                              withSessionID:self.currentSessionID
                                                            enforcingPolicy:_dataManager.policy ];
            
            [self recordEvent:e];
            
        }
        
        
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    
    if (self.enableLogging) {
        NSLog(@"QC Measurement: The location manager failed with error = %@", error );
    }
    
    self.geoCountry = nil;
    self.geoProvince = nil;
    self.geoCity = nil;
    
}

#pragma mark - User Privacy Management
@synthesize isOptedOut=_isOptedOut;

+(BOOL)isOptedOutStatus {
    
    // check Quantcast opt-out status
    
    UIPasteboard* optOutPastboard = [UIPasteboard pasteboardWithName:QCMEASUREMENT_OPTOUT_PASTEBOARD create:NO];
    
    // if there is no pasteboard, the user has not opted out
    if (nil != optOutPastboard) {
        optOutPastboard.persistent = YES;

        // if there is a pastboard, check the contents to verify opt-out status.
        if ( [QCMEASUREMENT_OPTOUT_STRING compare:[optOutPastboard string]] == NSOrderedSame ) {
            return YES;
        }
    }
    
    return NO;
}

-(void)setOptOutStatus:(BOOL)inOptOutStatus {
    
    if ( _isOptedOut != inOptOutStatus ) {
        _isOptedOut = inOptOutStatus;
        
        _dataManager.isOptOut = inOptOutStatus;

        if ( inOptOutStatus ) {
            // setting the data manager to opt out will cause the cache directory to be emptied. No need to do further work here deleting files.
            
            // set data in pastboard to persist opt-out status and communicate with other apps using Quantcast Measurement
            UIPasteboard* optOutPastboard = [UIPasteboard pasteboardWithName:QCMEASUREMENT_OPTOUT_PASTEBOARD create:YES];
            optOutPastboard.persistent = YES;
            [optOutPastboard setString:QCMEASUREMENT_OPTOUT_STRING];
            
            
            // stop the various services
            
            [self stopGeoLocationMeasurement];
            [self stopReachabilityNotifier];
        }
        else {
            // remove opt-out pastboard if it exists
            [UIPasteboard removePasteboardWithName:QCMEASUREMENT_OPTOUT_PASTEBOARD];
            
            // if the opt out status goes to NO (meaning we can do measurement), begin a new session
            [self beginMeasurementSession:self.publisherCode withAppleAppId:( nil != self.appleAppID ? [self.appleAppID unsignedIntegerValue] : 0 ) labels:@"OPT-IN"];
            
            [self startGeoLocationMeasurement];
            [self startReachabilityNotifier];

        }
    }
    
}

-(void)displayUserPrivacyDialogOver:(UIViewController*)inCurrentViewController withDelegate:(id<QuantcastOptOutDelegate>)inDelegate {
 
    QuantcastOptOutViewController* optOutController = [[[QuantcastOptOutViewController alloc] initWithMeasurement:self delegate:inDelegate] autorelease];
    
    optOutController.modalPresentationStyle = UIModalPresentationFormSheet;
    
    if ([inCurrentViewController respondsToSelector:@selector(presentViewController:animated:completion:)]) {
        [inCurrentViewController presentViewController:optOutController animated:YES completion:NULL];
    }
    else {
        // pre-iOS 5
        [inCurrentViewController presentModalViewController:optOutController animated:YES];
    }

}

#pragma mark - Debugging
@synthesize enableLogging=_enableLogging;

-(void)setEnableLogging:(BOOL)inEnableLogging {
    _enableLogging = inEnableLogging;
    
    _dataManager.enableLogging=inEnableLogging;
}

- (NSString *)description {
    NSString* descStr = [NSString stringWithFormat:@"<QuantcastMeasurement %p: data manager = %@>", self, _dataManager];
    
    return descStr;
}

@end
