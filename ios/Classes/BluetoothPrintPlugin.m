#import "BluetoothPrintPlugin.h"
#import "ConnecterManager.h"
#import "EscCommand.h"
#import "TscCommand.h"

@interface BluetoothPrintPlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *channel;
@property(nonatomic, retain) BluetoothPrintStreamHandler *stateStreamHandler;
@property(nonatomic, assign) int stateID;
@property(nonatomic) NSMutableDictionary *scannedPeripherals;
@property(nonatomic, strong) CBPeripheral *activePeripheral;
@property(nonatomic, strong) NSMutableArray *debugLogs;
@property(nonatomic, assign) NSInteger lastCentralState;
@property(nonatomic, assign) NSUInteger instanceID;

- (void)addDebugLog:(NSString *)event peripheral:(CBPeripheral *)peripheral details:(NSDictionary *)details;

@end

@implementation BluetoothPrintPlugin

static BluetoothPrintPlugin *sharedBluetoothPrintPlugin;
static NSUInteger bluetoothPrintPluginInstanceCounter = 0;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:NAMESPACE @"/methods"
            binaryMessenger:[registrar messenger]];
  FlutterEventChannel* stateChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/state" binaryMessenger:[registrar messenger]];
  if (sharedBluetoothPrintPlugin == nil) {
    sharedBluetoothPrintPlugin = [[BluetoothPrintPlugin alloc] init];
  }
  BluetoothPrintPlugin* instance = sharedBluetoothPrintPlugin;

  instance.channel = channel;
  instance.registrar = registrar;
  if (instance.scannedPeripherals == nil) {
    instance.scannedPeripherals = [NSMutableDictionary new];
  }
  if (instance.debugLogs == nil) {
    instance.debugLogs = [NSMutableArray new];
  }
  instance.lastCentralState = -1;
    
  // STATE
  if (instance.stateStreamHandler == nil) {
    instance.stateStreamHandler = [[BluetoothPrintStreamHandler alloc] init];
  }
  [stateChannel setStreamHandler:instance.stateStreamHandler];

  [registrar addMethodCallDelegate:instance channel:channel];
  [instance addDebugLog:@"pluginRegistered" peripheral:nil details:@{}];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    bluetoothPrintPluginInstanceCounter += 1;
    _instanceID = bluetoothPrintPluginInstanceCounter;
    _lastCentralState = -1;
    _debugLogs = [NSMutableArray new];
    _scannedPeripherals = [NSMutableDictionary new];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSLog(@"call method -> %@", call.method);
  [self addDebugLog:[NSString stringWithFormat:@"method.%@", call.method] peripheral:self.activePeripheral details:@{}];
    
  if ([@"state" isEqualToString:call.method]) {
    result([NSNumber numberWithInt:self.stateID]);
  } else if ([@"getDebugLogs" isEqualToString:call.method]) {
    @synchronized (self.debugLogs) {
      result([self.debugLogs copy]);
    }
  } else if ([@"clearDebugLogs" isEqualToString:call.method]) {
    @synchronized (self.debugLogs) {
      [self.debugLogs removeAllObjects];
    }
    [self addDebugLog:@"logsCleared" peripheral:self.activePeripheral details:@{}];
    result(nil);
  } else if([@"isAvailable" isEqualToString:call.method]) {
    
    result(@(YES));
  } else if([@"isConnected" isEqualToString:call.method]) {
    
    bool isConnected = self.stateID == 1;

    result(@(isConnected));
  } else if([@"isOn" isEqualToString:call.method]) {
    result(@(YES));
  } else if([@"startScan" isEqualToString:call.method]) {
      NSLog(@"getDevices method -> %@", call.method);
      [self addDebugLog:@"startScan" peripheral:self.activePeripheral details:@{
        @"bleConnecterExists": @(Manager.bleConnecter != nil)
      }];
      [self.scannedPeripherals removeAllObjects];
      
      if (Manager.bleConnecter == nil) {
          [Manager didUpdateState:^(NSInteger state) {
              self.lastCentralState = state;
              [self addDebugLog:@"centralManagerDidUpdateState" peripheral:self.activePeripheral details:@{
                @"rawState": @(state)
              }];
              switch (state) {
                  case CBCentralManagerStateUnsupported:
                      NSLog(@"The platform/hardware doesn't support Bluetooth Low Energy.");
                      break;
                  case CBCentralManagerStateUnauthorized:
                      NSLog(@"The app is not authorized to use Bluetooth Low Energy.");
                      break;
                  case CBCentralManagerStatePoweredOff:
                      NSLog(@"Bluetooth is currently powered off.");
                      break;
                  case CBCentralManagerStatePoweredOn:
                      [self startScan];
                      NSLog(@"Bluetooth power on");
                      break;
                  case CBCentralManagerStateUnknown:
                  default:
                      break;
              }
          }];
      } else {
          [self startScan];
      }
      
    result(nil);
  } else if([@"stopScan" isEqualToString:call.method]) {
    [self addDebugLog:@"stopScan" peripheral:self.activePeripheral details:@{}];
    [Manager stopScan];
    result(nil);
  } else if([@"connect" isEqualToString:call.method]) {
    NSDictionary *device = [call arguments];
    @try {
      NSLog(@"connect device begin -> %@", [device objectForKey:@"name"]);
      CBPeripheral *peripheral = [_scannedPeripherals objectForKey:[device objectForKey:@"address"]];
      if (peripheral == nil) {
        [self addDebugLog:@"connectPeripheralMissing" peripheral:nil details:@{
          @"requestedAddress": [device objectForKey:@"address"] ?: @"",
          @"requestedName": [device objectForKey:@"name"] ?: @"",
          @"scannedCount": @([self.scannedPeripherals count])
        }];
        result([FlutterError errorWithCode:@"PERIPHERAL_NOT_FOUND"
                                   message:@"Peripheral was not found in scanned peripherals."
                                   details:device]);
        return;
      }
      self.activePeripheral = peripheral;
      peripheral.delegate = self;
      [self addDebugLog:@"connectCalled" peripheral:peripheral details:@{
        @"managerPointer": [NSString stringWithFormat:@"%p", Manager],
        @"bleConnecterPointer": [NSString stringWithFormat:@"%p", Manager.bleConnecter],
        @"pluginPointer": [NSString stringWithFormat:@"%p", self]
      }];
        
      self.state = ^(ConnectState state) {
        [self updateConnectState:state];
      };
      [Manager connectPeripheral:peripheral options:nil timeout:2 connectBlack: self.state];
      
      result(nil);
    } @catch(FlutterError *e) {
      [self addDebugLog:@"connectFlutterError" peripheral:self.activePeripheral details:@{
        @"error": [e description] ?: @""
      }];
      result(e);
    } @catch(NSException *exception) {
      [self addDebugLog:@"connectException" peripheral:self.activePeripheral details:@{
        @"error": exception.reason ?: @""
      }];
      result([FlutterError errorWithCode:@"CONNECT_EXCEPTION"
                                 message:exception.reason
                                 details:nil]);
    }
  } else if([@"disconnect" isEqualToString:call.method]) {
    @try {
      [self addDebugLog:@"disconnectCalled" peripheral:self.activePeripheral details:@{}];
      [Manager close];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"print" isEqualToString:call.method]) {
     @try {
       
       result(nil);
     } @catch(FlutterError *e) {
       result(e);
     }
  } else if([@"printReceipt" isEqualToString:call.method]) {
       @try {
         NSDictionary *args = [call arguments];
         [self addDebugLog:@"printReceipt" peripheral:self.activePeripheral details:@{
           @"connectedState": @(self.stateID)
         }];
         [Manager write:[self mapToEscCommand:args]];
         result(nil);
       } @catch(FlutterError *e) {
         result(e);
       }
  } else if([@"printLabel" isEqualToString:call.method]) {
     @try {
       NSDictionary *args = [call arguments];
       [Manager write:[self mapToTscCommand:args]];
       result(nil);
     } @catch(FlutterError *e) {
       result(e);
     }
  } else if([@"printTest" isEqualToString:call.method]) {
     @try {
       
       result(nil);
     } @catch(FlutterError *e) {
       result(e);
     }
  } else if([@"openCashDrawer" isEqualToString:call.method]) {
    @try {
        NSDictionary *args = [call arguments];
        NSNumber *mParam = args[@"m"];
        NSNumber *t1Param = args[@"t1"];
        NSNumber *t2Param = args[@"t2"];
        
        if (!mParam || !t1Param || !t2Param) {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"Missing parameters m, t1, or t2."
                                       details:nil]);
            return;
        }
        
        // Create EscCommand and add open cash drawer command
        EscCommand *command = [[EscCommand alloc] init];
        [command addOpenCashDawer:[mParam intValue] :[t1Param intValue] :[t2Param intValue]];
        NSData *commandData = [command getCommand];
        
        // Send the command to the printer
        [Manager write:commandData];

        result(nil);
    } @catch(NSException *exception) {
        result([FlutterError errorWithCode:@"UNEXPECTED_ERROR"
                                   message:exception.reason
                                   details:nil]);
    }
  } else {
    result(FlutterMethodNotImplemented);
  }
}


-(NSData *)mapToTscCommand:(NSDictionary *) args {
    NSDictionary *config = [args objectForKey:@"config"];
    NSMutableArray *list = [args objectForKey:@"data"];
    
    NSNumber *width = ![config objectForKey:@"width"]?@"48" : [config objectForKey:@"width"];
    NSNumber *height = ![config objectForKey:@"height"]?@"80" : [config objectForKey:@"height"];
    NSNumber *gap = ![config objectForKey:@"gap"]?@"2" : [config objectForKey:@"gap"];
    
    TscCommand *command = [[TscCommand alloc]init];
    // 设置标签尺寸宽高，按照实际尺寸设置 单位mm
    [command addSize:[width intValue] :[height intValue]];
    // 设置标签间隙，按照实际尺寸设置，如果为无间隙纸则设置为0 单位mm
    [command addGapWithM:[gap intValue] withN:0];
    // 设置原点坐标
    [command addReference:0 :0];
    // 撕纸模式开启
    [command addTear:@"ON"];
    // 开启带Response的打印，用于连续打印
    [command addQueryPrinterStatus:ON];
    // 清除打印缓冲区
    [command addCls];
    
    for(NSDictionary *m in list){
        
        NSString *type = [m objectForKey:@"type"];
        NSString *content = [m objectForKey:@"content"];
        NSNumber *x = ![m objectForKey:@"x"]?@0 : [m objectForKey:@"x"];
        NSNumber *y = ![m objectForKey:@"y"]?@0 : [m objectForKey:@"y"];
        
        if([@"text" isEqualToString:type]){
            [command addTextwithX:[x intValue] withY:[y intValue] withFont:@"TSS24.BF2" withRotation:0 withXscal:1 withYscal:1 withText:content];
        }else if([@"barcode" isEqualToString:type]){
            [command add1DBarcode:[x intValue] :[y intValue] :@"CODE128" :100 :1 :0 :2 :2 :content];
        }else if([@"qrcode" isEqualToString:type]){
            [command addQRCode:[x intValue] :[y intValue] :@"L" :5 :@"A" :0 :content];
        }else if([@"image" isEqualToString:type]){
          NSData *decodeData = [[NSData alloc] initWithBase64EncodedString:content options:0];
          UIImage *image = [UIImage imageWithData:decodeData];
          [command addBitmapwithX:[x intValue] withY:[y intValue] withMode:0 withWidth:300 withImage:image];
        }
    }
    
    [command addPrint:1 :1];
    return [command getCommand];
}

-(NSData *)mapToEscCommand:(NSDictionary *) args {
    NSDictionary *config = [args objectForKey:@"config"];
    NSMutableArray *list = [args objectForKey:@"data"];
    NSString *imageMode = ![config objectForKey:@"imageMode"] ? @"resizedPng" : [config objectForKey:@"imageMode"];
    NSNumber *initialFeedLines = ![config objectForKey:@"initialFeedLines"] ? @0 : [config objectForKey:@"initialFeedLines"];
    NSNumber *finalFeedLines = ![config objectForKey:@"finalFeedLines"] ? @0 : [config objectForKey:@"finalFeedLines"];
    
    EscCommand *command = [[EscCommand alloc]init];
    [command addInitializePrinter];
    if ([initialFeedLines intValue] > 0) {
        [command addPrintAndFeedLines:[initialFeedLines intValue]];
    }

    for(NSDictionary *m in list){
        
        NSString *type = [m objectForKey:@"type"];
        NSString *content = [m objectForKey:@"content"];
        NSNumber *align = ![m objectForKey:@"align"]?@0 : [m objectForKey:@"align"];
        NSNumber *size = ![m objectForKey:@"size"]?@4 : [m objectForKey:@"size"];
        NSNumber *weight = ![m objectForKey:@"weight"]?@0 : [m objectForKey:@"weight"];
        NSNumber *width = ![m objectForKey:@"width"]?@0 : [m objectForKey:@"width"];
        NSNumber *height = ![m objectForKey:@"height"]?@0 : [m objectForKey:@"height"];
        NSNumber *underline = ![m objectForKey:@"underline"]?@0 : [m objectForKey:@"underline"];
        NSNumber *linefeed = ![m objectForKey:@"linefeed"]?@0 : [m objectForKey:@"linefeed"];
        
        //内容居左（默认居左）
        [command addSetJustification:[align intValue]];
        
        if([@"text" isEqualToString:type]){
            
            Byte mode = PrintModeEnumDefault;
            if ([weight intValue] == 1) mode = mode | PrintModeEnumBold;
            if ([underline intValue] == 1) mode = mode | PrintModeEnumUnderline;
            [command addPrintMode: mode];

            Byte size = CharacterSizeEnumDefault;
            if ([height intValue] == 1) size = size | CharacterSizeEnumDoubleHeight;
            if ([width intValue] == 1) size = size | CharacterSizeEnumDoubleWidth;
            [command addSetCharcterSize: size];
            
            [command addText:content];
            [command addPrintMode: PrintModeEnumDefault];
            [command addSetCharcterSize: CharacterSizeEnumDefault];

        }else if([@"barcode" isEqualToString:type]){
            [command addSetBarcodeWidth:2];
            [command addSetBarcodeHeight:60];
            [command addSetBarcodeHRPosition:2];
            [command addCODE128:'B' : content];
        }else if([@"qrcode" isEqualToString:type]){
           //  This code snippet has been copied from https://stackoverflow.com/q/34608340/1993514
           int store_len = (int )content.length + 3;
           int pl = (store_len % 256);
           [command addQRCodeSizewithpL:0  withpH:0    withcn:49 withyfn:67 withn:[size intValue]];
           [command addQRCodeLevelwithpL:0 withpH:0    withcn:49 withyfn:69 withn:[size intValue]];
           [command addQRCodeSavewithpL:pl withpH:0    withcn:49 withyfn:80 withm:48 withData:[content dataUsingEncoding:NSASCIIStringEncoding]];
           [command addQRCodePrintwithpL:3 withpH:pl+3 withcn:49 withyfn:81 withm:48];
        }else if([@"image" isEqualToString:type]){
            NSData *decodeData = [[NSData alloc] initWithBase64EncodedString:content options:0];
            UIImage *image = [UIImage imageWithData:decodeData];

            if (image == nil || image.size.width <= 0 || image.size.height <= 0) {
                continue;
            }

            CGFloat maxWidth = [width floatValue] > 0 ? [width floatValue] : image.size.width;
            maxWidth = floor(maxWidth / 8.0) * 8.0;
            if (maxWidth < 8) {
                maxWidth = 8;
            }
            UIImage *imageToPrint = image;

            if ([@"origin" isEqualToString:imageMode]) {
                [command addOriginrastBitImage:imageToPrint];
            } else if ([@"originWidth" isEqualToString:imageMode]) {
                [command addOriginrastBitImage:imageToPrint width:(int)maxWidth];
            } else {
                CGSize originalSize = image.size;
                CGFloat scaleFactor = maxWidth / originalSize.width;
                CGSize scaledSize = CGSizeMake(originalSize.width * scaleFactor, originalSize.height * scaleFactor);

                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:scaledSize];
                NSData *renderedImageData;

                if ([@"resizedJpeg" isEqualToString:imageMode] || [@"resizedJpegWidth" isEqualToString:imageMode]) {
                    renderedImageData = [renderer JPEGDataWithCompressionQuality:1 actions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                        [image drawInRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height)];
                    }];
                } else {
                    renderedImageData = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
                        [image drawInRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height)];
                    }];
                }

                imageToPrint = [UIImage imageWithData:renderedImageData];
                if (imageToPrint == nil || imageToPrint.size.width <= 0 || imageToPrint.size.height <= 0) {
                    continue;
                }

                if ([@"resizedJpegWidth" isEqualToString:imageMode] || [@"resizedPngWidth" isEqualToString:imageMode]) {
                    [command addOriginrastBitImage:imageToPrint width:(int)maxWidth];
                } else if ([@"printingArea" isEqualToString:imageMode]) {
                    [command addSetPrintingAreaWidth:(int)maxWidth];
                    [command addOriginrastBitImage:imageToPrint];
                } else {
                    [command addOriginrastBitImage:imageToPrint];
                }
            }
        }
        
        if([linefeed isEqualToNumber:@1]){
            [command addPrintAndLineFeed];
        }
    }
    
    if ([finalFeedLines intValue] > 0) {
        [command addPrintAndFeedLines:[finalFeedLines intValue]];
    }
    return [command getCommand];
}


-(void)startScan {
    [Manager scanForPeripheralsWithServices:nil options:nil discover:^(CBPeripheral * _Nullable peripheral, NSDictionary<NSString *,id> * _Nullable advertisementData, NSNumber * _Nullable RSSI) {
        if (peripheral.name != nil) {
            
            NSLog(@"find device -> %@", peripheral.name);
            [self addDebugLog:@"didDiscover" peripheral:peripheral details:@{
              @"RSSI": RSSI ?: @0
            }];
            [self.scannedPeripherals setObject:peripheral forKey:[[peripheral identifier] UUIDString]];
            
            NSDictionary *device = [NSDictionary dictionaryWithObjectsAndKeys:peripheral.identifier.UUIDString,@"address",peripheral.name,@"name",nil,@"type",nil];
            [_channel invokeMethod:@"ScanResult" arguments:device];
        }
    }];
    
}

-(void)updateConnectState:(ConnectState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *ret = @0;
        NSString *eventName = @"connectStateUnknown";
        switch (state) {
            case CONNECT_STATE_CONNECTING:
                NSLog(@"status -> %@", @"连接状态：连接中....");
                eventName = @"connectStateConnecting";
                ret = @2;
                self.stateID = 2;
                break;
            case CONNECT_STATE_CONNECTED:
                NSLog(@"status -> %@", @"连接状态：连接成功");
                eventName = @"didConnect";
                ret = @1;
                self.stateID = 1;
                break;
            case CONNECT_STATE_FAILT:
                NSLog(@"status -> %@", @"连接状态：连接失败");
                eventName = @"didFailToConnect";
                ret = @0;
                break;
            case CONNECT_STATE_DISCONNECT:
                NSLog(@"status -> %@", @"连接状态：断开连接");
                eventName = @"didDisconnectPeripheral";
                ret = @0;
                self.stateID = -1;
                break;
            default:
                NSLog(@"status -> %@", @"连接状态：连接超时");
                eventName = @"connectStateTimeout";
                ret = @0;
                self.stateID = -1;
                break;
        }
        [self addDebugLog:eventName peripheral:self.activePeripheral details:@{
          @"stateValue": @(state),
          @"flutterState": ret,
          @"streamAttached": @(self.stateStreamHandler.sink != nil)
        }];
        
         NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:ret,@"id",nil];
        if(_stateStreamHandler.sink != nil) {
          self.stateStreamHandler.sink([dict objectForKey:@"id"]);
        } else {
          [self addDebugLog:@"stateDroppedNoEventSink" peripheral:self.activePeripheral details:@{
            @"stateValue": @(state)
          }];
        }
    });
}

- (void)addDebugLog:(NSString *)event peripheral:(CBPeripheral *)peripheral details:(NSDictionary *)details {
    if (self.debugLogs == nil) {
        self.debugLogs = [NSMutableArray new];
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"timestamp"] = [self isoTimestamp];
    entry[@"event"] = event ?: @"";
    entry[@"thread"] = [NSThread isMainThread] ? @"main" : [[NSThread currentThread] description];
    entry[@"centralState"] = [self centralStateLabel:self.lastCentralState];
    entry[@"centralStateValue"] = @(self.lastCentralState);
    entry[@"pluginInstanceID"] = @(self.instanceID);
    entry[@"pluginPointer"] = [NSString stringWithFormat:@"%p", self];
    entry[@"managerPointer"] = [NSString stringWithFormat:@"%p", Manager];
    entry[@"bleConnecterPointer"] = [NSString stringWithFormat:@"%p", Manager.bleConnecter];
    entry[@"streamAttached"] = @(self.stateStreamHandler.sink != nil);
    if (peripheral != nil) {
        entry[@"peripheralUUID"] = peripheral.identifier.UUIDString ?: @"";
        entry[@"peripheralName"] = peripheral.name ?: @"";
        entry[@"peripheralState"] = [self peripheralStateLabel:peripheral.state];
        entry[@"peripheralPointer"] = [NSString stringWithFormat:@"%p", peripheral];
    }
    if (details != nil && [details count] > 0) {
        entry[@"details"] = details;
    }
    @synchronized (self.debugLogs) {
        [self.debugLogs addObject:entry];
        if ([self.debugLogs count] > 500) {
            [self.debugLogs removeObjectAtIndex:0];
        }
    }
    NSLog(@"[BluetoothPrintDebug] %@", entry);
}

- (NSString *)isoTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

- (NSString *)centralStateLabel:(NSInteger)state {
    switch (state) {
        case CBCentralManagerStateUnsupported:
            return @"unsupported";
        case CBCentralManagerStateUnauthorized:
            return @"unauthorized";
        case CBCentralManagerStatePoweredOff:
            return @"poweredOff";
        case CBCentralManagerStatePoweredOn:
            return @"poweredOn";
        case CBCentralManagerStateResetting:
            return @"resetting";
        case CBCentralManagerStateUnknown:
            return @"unknown";
        default:
            return @"notInitialized";
    }
}

- (NSString *)peripheralStateLabel:(CBPeripheralState)state {
    switch (state) {
        case CBPeripheralStateDisconnected:
            return @"disconnected";
        case CBPeripheralStateConnecting:
            return @"connecting";
        case CBPeripheralStateConnected:
            return @"connected";
        case CBPeripheralStateDisconnecting:
            return @"disconnecting";
    }
}

@end

@implementation BluetoothPrintStreamHandler

- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
  self.sink = eventSink;
  NSLog(@"[BluetoothPrintDebug] stream onListen");
  [sharedBluetoothPrintPlugin addDebugLog:@"streamOnListen" peripheral:sharedBluetoothPrintPlugin.activePeripheral details:@{}];
  return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
  NSLog(@"[BluetoothPrintDebug] stream onCancel");
  [sharedBluetoothPrintPlugin addDebugLog:@"streamOnCancel" peripheral:sharedBluetoothPrintPlugin.activePeripheral details:@{}];
  self.sink = nil;
  return nil;
}

@end
