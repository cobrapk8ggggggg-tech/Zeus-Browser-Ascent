import Foundation
import Combine
import WebKit
import UIKit
import ImageIO
import CoreGraphics

@MainActor private final class ComicMessageRouter:NSObject,WKScriptMessageHandler{
    static let shared=ComicMessageRouter()
    let pages=NSMapTable<WKWebView,ComicTranslation>.weakToWeakObjects()
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){if let view=message.webView{pages.object(forKey:view)?.receive(message)}}
}
@MainActor final class ComicTranslation:NSObject,ObservableObject{
    static let world=WKContentWorld.world(name:"ZEUS.ComicTranslation")
    static let script=Bundle.main.url(forResource:"comic-images",withExtension:"js").flatMap{try? String(contentsOf:$0,encoding:.utf8)} ?? ""
    weak var model:BrowserModel?
    weak var tab:BrowserTab?
    @Published var active=false
    @Published var running=false
    @Published var paused=false
    @Published var completed=0
    private(set) var ocrRuns=0
    @Published var stage=""
    @Published var error:String?
    @Published var storageNotice:String?
    private var work:Task<Void,Never>?
    private var epoch=UUID()
    private var frames:[String:WKFrameInfo]=[:]
    private var documents:[String:ComicEnvelope]=[:]
    private var done=Set<String>()
    private var failed=Set<String>()
    private var pending=false
    private var readings:[String:ComicReading]=[:]
    private var textResults:[String:[TranslationSegment]]=[:]
    private var speechTexts:[String:String]=[:]
    private var fetched:[String:Data]=[:]
    private var fetchedOrder:[String]=[]
    private var resolvedScripts:[String:(String,Int)]=[:]
    private var observer:NSObjectProtocol?
    var preferences:ComicPreferences{model?.data.settings.comicTranslation ?? ComicPreferences()}
    init(model:BrowserModel,tab:BrowserTab){self.model=model;self.tab=tab;super.init();observer=NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main){[weak self]_ in Task{@MainActor in self?.pause();await ComicOCR.shared.purge();await ComicPaddle.shared.purge();await ComicLocalTranslator.shared.unload()}}}
    deinit{if let observer{NotificationCenter.default.removeObserver(observer)}}
    func attach(to view:WKWebView,installScript:Bool=true){
        ComicMessageRouter.shared.pages.setObject(self,forKey:view)
        view.configuration.userContentController.removeScriptMessageHandler(forName:"zeusComic",contentWorld:Self.world)
        view.configuration.userContentController.add(ComicMessageRouter.shared,contentWorld:Self.world,name:"zeusComic")
        if installScript{view.configuration.userContentController.addUserScript(WKUserScript(source:Self.script,injectionTime:.atDocumentEnd,forMainFrameOnly:false,in:Self.world))}
    }
    func receive(_ message:WKScriptMessage){
        guard let model,let tab,message.webView===tab.webView,model.profile.id==tab.profileID,!model.requiresUnlock,let body=message.body as? [String:String],let document=body["document"],document.count<80 else{return}
        if frames.count<64||frames[document] != nil{frames[document]=message.frameInfo}
        if preferences.automatic,model.current?.id==tab.id,!active{start()}
        if active,model.current?.id==tab.id{schedule()}
    }
    private func valid(_ ticket:UUID)throws{
        try Task.checkCancellation()
        guard ticket==epoch,let model,let tab,model.profile.id==tab.profileID,!model.requiresUnlock,tab.webView != nil,model.tabs.contains(where:{$0===tab})else{throw CancellationError()}
    }
    private func call(_ code:String,args:[String:Any]=[:],frame:WKFrameInfo?)async throws->Any{
        guard let view=tab?.webView else{throw CancellationError()}
        return try await view.callAsyncJavaScript(code,arguments:args,in:frame?.isMainFrame==true ? nil:frame,contentWorld:Self.world) ?? NSNull()
    }
    func start(){guard let model,let tab,!tab.isHome,!model.requiresUnlock,model.profile.id==tab.profileID else{return};ComicFonts.registerAll();active=true;paused=false;error=nil;failed.removeAll();schedule()}
    func navigationStarted(){pause();active=false;completed=0;ocrRuns=0;done.removeAll();failed.removeAll();frames.removeAll();documents.removeAll();readings.removeAll();textResults.removeAll();speechTexts.removeAll();fetched.removeAll();fetchedOrder.removeAll();resolvedScripts.removeAll();error=nil}
    func pause(){paused=true;epoch=UUID();work?.cancel();work=nil;running=false;pending=false;for frame in frames.values{Task{_ = try? await call("globalThis.zeusComic?.releaseAll?.()",frame:frame)}}}
    func becameVisible(){if active||preferences.automatic{start()}}
    func restore()async{pause();active=false;for frame in frames.values{_ = try? await call("globalThis.zeusComic?.restore()",frame:frame)};_ = try? await call("globalThis.zeusComic?.restore()",frame:nil);done.removeAll();failed.removeAll();completed=0;error=nil}
    private func schedule(){if running{pending=true;return};guard active && !paused else{return};let ticket=epoch;running=true
        work=Task{[weak self]in guard let self else{return};defer{if epoch==ticket{running=false;work=nil;if pending{pending=false;schedule()}}}
            do{
                _ = try await call(Self.script,frame:nil)
                let id=try await call("return zeusComic.documentID",frame:nil)as? String ?? ""
                let children=frames.filter{!$0.value.isMainFrame}.map{($0.key,Optional($0.value))}
                for (document,frame) in [(id,Optional<WKFrameInfo>.none)]+children{
                    try valid(ticket)
                    do{try await sweep(document:document,frame:frame,ticket:ticket)}catch is CancellationError{throw CancellationError()}catch{if (error as NSError).domain==WKError.errorDomain,frame != nil{frames[document]=nil;continue};self.error=error.localizedDescription}
                }
            }catch is CancellationError{}catch{if epoch==ticket{self.error=error.localizedDescription}}
        }
    }
    private func sweep(document:String,frame:WKFrameInfo?,ticket:UUID)async throws{
        guard let model,let tab else{return}
        let owner=model.profile.id,prefs=preferences,translation=preferences.resolvedTranslation(model.data.settings)
        let provider=model.data.settings.aiProviders?.first{$0.id==translation.providerID}
        let translationMark=ComicIdentity.settings(prefs,translation:translation,provider:provider)+"|"+prefs.engine.rawValue+"|local:\(prefs.localModel)|"+ComicLocalTranslator.modelIdentity
        let mark=translationMark+"|"+(prefs.fontName ?? "default")+"|\(prefs.fontScale)|"+(prefs.textColor ?? "auto")
        let persistent=translation.keepsTranslations && !model.profile.isPrivate
        let generation=try await call("return zeusComic.resume(mark)",args:["mark":mark],frame:frame)as? Int ?? 0
        let value=try await call("return zeusComic.scan(wake)",args:["wake":prefs.readAhead],frame:frame)
        let data=try JSONSerialization.data(withJSONObject:value),envelope=try JSONDecoder().decode(ComicEnvelope.self,from:data)
        guard envelope.document==document else{return};documents[document]=envelope
        let ordered=envelope.items.filter{!$0.pending&&$0.width>0&&$0.height>0}.sorted{a,b in
            let d1=max(0,a.y-envelope.scroll-envelope.viewport,envelope.scroll-a.y-a.h),d2=max(0,b.y-envelope.scroll-envelope.viewport,envelope.scroll-b.y-b.h);return d1<d2
        }
        // Bounded sweep; rescan geometry before the next window after a scroll.
        for candidate in ordered.prefix(prefs.readAhead ? 16:4){
            try valid(ticket)
            let allRegions=ComicGeometry.regions(width:candidate.width,height:candidate.height,maximumPixels:7_000_000)
            let regions=ComicGeometry.prioritized(allRegions,candidate:candidate,scroll:envelope.scroll,viewport:envelope.viewport,readAhead:prefs.readAhead)
            if allRegions.isEmpty{failed.insert(candidate.id);continue}
            for region in regions{
                let job="\(document)|\(candidate.id)|\(candidate.revision)|\(region.y)|\(mark)"
                if done.contains(job)||failed.contains(job){continue}
                if try await call("return zeusComic.has(id,revision,mark)",args:["id":candidate.id,"revision":candidate.revision,"mark":mark],frame:frame)as? Bool==true{done.insert(job);continue}
                do{
                    stage="جلب الصورة"
                    if !prefs.showUntranslated{_ = try await call("zeusComic.hold(id,revision)",args:["id":candidate.id,"revision":candidate.revision],frame:frame)}
                    let bytes=try await capture(candidate,region:region,frame:frame,ticket:ticket)
                    try valid(ticket)
                    let center=try await Task.detached{try ComicPixels.decode(bytes)}.value
                    let neighbours=ComicWindow.neighbours(of:candidate,in:envelope.items)
                    var before:CGImage?,after:CGImage?
                    let contextRows=max(0,min(256,(8_000_000/center.width-center.height)/2))
                    if contextRows>0,region.y==0,let previous=neighbours.before{
                        let height=min(previous.height,max(1,contextRows*previous.width/center.width)),area=ComicRegion(y:previous.height-height,width:previous.width,height:height,coreTop:0,coreBottom:height)
                        let context=try await capture(previous,region:area,frame:frame,ticket:ticket)
                        before=try await Task.detached{try ComicPixels.decode(context)}.value
                    }
                    if contextRows>0,region.y+region.height==candidate.height,let next=neighbours.after{
                        let height=min(next.height,max(1,contextRows*next.width/center.width)),area=ComicRegion(y:0,width:next.width,height:height,coreTop:0,coreBottom:height)
                        let context=try await capture(next,region:area,frame:frame,ticket:ticket)
                        after=try await Task.detached{try ComicPixels.decode(context)}.value
                    }
                    let window=try await Task.detached{try ComicWindow.join(center,before:before,after:after)}.value
                    let image=window.image,offset=window.offset
                    let imageHash=try await Task.detached{ComicIdentity.hash(try ComicPixels.png(image))}.value
                    let readingKey=imageHash+"|ocr-v3|\(prefs.source)|\(prefs.mode.rawValue)"
                    stage="قراءة الفقاعات"
                    let reading:ComicReading
                    if let saved=readings[readingKey]{reading=saved}
                    else if persistent,let stored=await ComicMemory.shared.data(profile:owner,layer:.reading,key:readingKey),let saved=try? JSONDecoder().decode(ComicReading.self,from:stored){reading=saved}
                    else{ocrRuns+=1;reading=try await ComicOCR.shared.read(image,source:prefs.source == "auto" ? (resolvedScripts[document].flatMap{$0.1%3==0 ? nil:$0.0} ?? "auto"):prefs.source,mode:prefs.mode)
                        try valid(ticket)
                        if persistent{do{try await ComicMemory.shared.save(JSONEncoder().encode(reading),profile:owner,layer:.reading,key:readingKey)}catch{storageNotice="تعذّر حفظ قراءة الصورة؛ ستظل الجلسة الحالية متاحة."}}
                    }
                    if readings.count>=128{readings.removeAll()};readings[readingKey]=reading
                    let vote=resolvedScripts[document];resolvedScripts[document]=(reading.language,(vote?.1 ?? 0)+1)
                    try valid(ticket)
                    // A speech touching this core is rendered from its complete context,
                    // then clipped to this core. Its neighbour renders the other half.
                    let core=reading.speeches.filter{$0.rect.maxY>CGFloat(region.coreTop+offset)&&$0.rect.minY<CGFloat(region.coreBottom+offset)}
                    if core.isEmpty{done.insert(job);_ = try await call("zeusComic.release(id)",args:["id":candidate.id],frame:frame);continue}
                    stage="ترجمة الحوار"
                    let segments=core.map{TranslationSegment(id:$0.id,text:$0.text)}
                    let translationKey=readingKey+"|\(translationMark)|"+ComicIdentity.segmentIdentity(segments)
                    let translated:[TranslationSegment]
                    if let saved=textResults[translationKey]{translated=saved}
                    else if persistent,let stored=await ComicMemory.shared.data(profile:owner,layer:.translation,key:translationKey),let saved=try? JSONDecoder().decode([TranslationSegment].self,from:stored){translated=saved}
                    else{translated=try await translateSpeeches(segments,reading:reading,namespace:translationMark+"|"+ComicIdentity.hash(envelope.url),profile:owner,persistent:persistent,preferences:prefs,translation:translation,provider:provider,ticket:ticket)
                        try valid(ticket)
                        if persistent{do{try await ComicMemory.shared.save(JSONEncoder().encode(translated),profile:owner,layer:.translation,key:translationKey)}catch{storageNotice="تعذّر حفظ الترجمة على الجهاز."}}
                    }
                    if textResults.count>=64{textResults.removeAll()};textResults[translationKey]=translated
                    try valid(ticket);stage="تنظيف الفقاعات ورسم العربية"
                    let renderedKey=translationKey+"|render-v3|\(prefs.fontName ?? "default")|\(prefs.fontScale)|\(prefs.textColor ?? "auto")"
                    let rendered:Data
                    if persistent,let stored=await ComicMemory.shared.data(profile:owner,layer:.rendered,key:renderedKey){rendered=stored}
                    else{rendered=try await Task.detached{let drawn=try ComicPixels.render(image,speeches:core,translations:translated,target:translation.target,fontName:prefs.fontName,fontScale:prefs.fontScale,textColor:prefs.textColor)
                        // Only this core is applied. Recognition context is retained above/below.
                        let rect=CGRect(x:0,y:region.coreTop+offset,width:region.width,height:region.coreBottom-region.coreTop)
                        guard let crop=drawn.cropping(to:rect)else{throw ComicFailure.message("تعذّر قص منطقة الرسم.")};return try ComicPixels.png(crop)}.value
                        try valid(ticket)
                        if persistent{do{try await ComicMemory.shared.save(rendered,profile:owner,layer:.rendered,key:renderedKey)}catch{storageNotice="تعذّر حفظ الصورة المترجمة؛ النص المحفوظ يظل متاحًا."}}
                    }
                    try valid(ticket);stage="عرض الترجمة"
                    let outputRegion:[String:Int]=["x":0,"y":region.y+region.coreTop,"width":region.width,"height":region.coreBottom-region.coreTop]
                    let applied=try await apply(rendered,candidate:candidate,region:outputRegion,mark:mark,generation:generation,frame:frame,ticket:ticket)
                    guard applied else{throw ComicFailure.message("لم يسمح الموقع بعرض الصورة المترجمة؛ بقي الأصل متاحًا.")}
                    done.insert(job);completed+=1
                }catch is CancellationError{throw CancellationError()}catch{try valid(ticket);failed.insert(job);self.error=error.localizedDescription;_ = try? await call("zeusComic.release(id)",args:["id":candidate.id],frame:frame)}
                await Task.yield()
                if pending{return}
            }
        }
        // Mark only an image whose every region reached a terminal successful state.
        for candidate in ordered{let regions=ComicGeometry.regions(width:candidate.width,height:candidate.height,maximumPixels:7_000_000);if !regions.isEmpty&&regions.allSatisfy({done.contains("\(document)|\(candidate.id)|\(candidate.revision)|\($0.y)|\(mark)")}){_ = try? await call("zeusComic.mark(id,revision,mark)",args:["id":candidate.id,"revision":candidate.revision,"mark":mark],frame:frame)}}
        _=tab
    }
    private func translateSpeeches(_ segments:[TranslationSegment],reading:ComicReading,namespace:String,profile:UUID,persistent:Bool,preferences:ComicPreferences,translation:TranslationPreferences,provider:AIProviderConfiguration?,ticket:UUID)async throws->[TranslationSegment]{
        let namespace=namespace+"|"+reading.language
        func key(_ text:String)->String{ComicIdentity.hash(namespace+"\0"+text)}
        var values:[String:String]=[:]
        for segment in segments{if let value=speechTexts[key(segment.text)]{values[segment.text]=value}}
        if persistent{let saved=await ComicMemory.shared.lookupText(segments,namespace:namespace,profile:profile);values.merge(saved){_,saved in saved}}
        try valid(ticket)
        var unique=Set<String>()
        let missing=segments.filter{values[$0.text]==nil&&unique.insert($0.text).inserted}
        if !missing.isEmpty{
            let preceding=reading.speeches.prefix(while:{$0.id != missing.first?.id}).suffix(4).map(\.text)
            let response=try await ComicTextTranslator.translate(missing,source:reading.language,target:translation.target,preferences:translation,provider:provider,secret:AISecretVault.read(profile:profile,provider:translation.secretKey(provider:provider)),local:preferences.localModel,engine:preferences.engine,engineSecret:AISecretVault.read(profile:profile,provider:"comic-"+preferences.engine.rawValue),context:preceding)
            try valid(ticket)
            let originals=Dictionary(uniqueKeysWithValues:missing.map{($0.id,$0.text)})
            var fresh:[String:String]=[:]
            for item in response{if let original=originals[item.id]{fresh[original]=item.text}}
            guard fresh.count==missing.count else{throw ComicFailure.message("رد الترجمة لا يطابق الفقاعات.")}
            values.merge(fresh){_,new in new}
            if persistent,!(await ComicMemory.shared.saveText(fresh,namespace:namespace,profile:profile)){storageNotice="تعذّر حفظ بعض النصوص؛ قد تحتاج مساحة إضافية."}
        }
        try valid(ticket)
        if speechTexts.count>=8000{speechTexts.removeAll()}
        for (text,value)in values{speechTexts[key(text)]=value}
        return try segments.map{segment in guard let value=values[segment.text]else{throw ComicFailure.message("ترجمة ناقصة.")};return TranslationSegment(id:segment.id,text:value)}
    }
    private func capture(_ candidate:ComicCandidate,region:ComicRegion,frame:WKFrameInfo?,ticket:UUID)async throws->Data{
        do{
            let result=try await call("return await zeusComic.capture(id,revision,region)",args:["id":candidate.id,"revision":candidate.revision,"region":["x":region.x,"y":region.y,"width":region.width,"height":region.height]],frame:frame)as? [String:Any]
            guard let token=result?["token"]as? String,let length=result?["length"]as? Int,length>0,length<=33_554_432 else{throw ComicFailure.message("حمولة الصورة غير صالحة.")}
            defer{Task{_ = try? await call("zeusComic.drop(token)",args:["token":token],frame:frame)}}
            var output=Data();output.reserveCapacity(length)
            for offset in stride(from:0,to:length,by:65536){try valid(ticket);guard let part=try await call("return zeusComic.take(token,offset,count)",args:["token":token,"offset":offset,"count":min(65536,length-offset)],frame:frame)as? String,let bytes=Data(base64Encoded:part)else{throw ComicFailure.message("انقطع نقل الصورة.")};output.append(bytes)}
            guard output.count==length else{throw ComicFailure.message("صورة ناقصة.")};return output
        }catch{
            try valid(ticket)
            guard candidate.kind=="image",let tab,let model,let url=URL(string:candidate.source),["https","http"].contains(url.scheme),candidate.width>0,candidate.height>0 else{throw error}
            let data:Data,cacheKey=candidate.source+"|"+candidate.id+"|"+candidate.revision+"|"+(frame?.request.url?.absoluteString ?? tab.url)
            if let cached=fetched[cacheKey]{data=cached}else{data=try await ComicImageFetch.fetch(url,view:tab.webView,store:model.profiles.websiteDataStore(for:model.profile));fetched[cacheKey]=data;fetchedOrder.removeAll{$0==cacheKey};fetchedOrder.append(cacheKey)
                while fetchedOrder.count>4||fetched.values.reduce(0,{$0+$1.count})>33_554_432{let old=fetchedOrder.removeFirst();fetched[old]=nil}}
            return try await Task.detached{let crop=try ComicPixels.decodeRegion(data,region:region,expectedHeight:candidate.height);return try ComicPixels.png(crop)}.value
        }
    }
    private func apply(_ data:Data,candidate:ComicCandidate,region:[String:Int],mark:String,generation:Int,frame:WKFrameInfo?,ticket:UUID)async throws->Bool{
        guard data.count<=33_554_432 else{throw ComicFailure.message("الصورة المرسومة أكبر من حد النقل.")}
        let token=UUID().uuidString
        _ = try await call("zeusComic.outputStart(token,length)",args:["token":token,"length":data.count],frame:frame)
        defer{Task{_ = try? await call("zeusComic.outputDrop(token)",args:["token":token],frame:frame)}}
        for start in stride(from:0,to:data.count,by:49152){try valid(ticket);_ = try await call("zeusComic.outputPart(token,offset,data)",args:["token":token,"offset":start,"data":data.subdata(in:start..<min(start+49152,data.count)).base64EncodedString()],frame:frame)}
        try valid(ticket)
        return try await call("return await zeusComic.outputApply(token,id,revision,region,mark,generation)",args:["token":token,"id":candidate.id,"revision":candidate.revision,"region":region,"mark":mark,"generation":generation],frame:frame)as? Bool ?? false
    }
}

@MainActor enum ComicImageFetch{
    static func fetch(_ url:URL,view:WKWebView?,store:WKWebsiteDataStore)async throws->Data{
        guard url.user==nil,url.password==nil,let host=url.host,let page=view?.url else{throw URLError(.badURL)}
        // Do not turn page-controlled image addresses into access to local services.
        let privateHost=host=="localhost"||host=="::1"||host.hasPrefix("127.")||host.hasPrefix("10.")||host.hasPrefix("192.168.")||host.hasSuffix(".local")||host.hasPrefix("169.254.")
        guard !privateHost||page.host==host else{throw URLError(.noPermissionsToReadFile)}
        let cookies=await withCheckedContinuation{c in store.httpCookieStore.getAllCookies{c.resume(returning:$0)}}
        let configuration=URLSessionConfiguration.ephemeral;configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false;configuration.urlCache=nil
        let session=URLSession(configuration:configuration,delegate:ComicImageRedirects(cookies:cookies,origin:url),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:url);request.allHTTPHeaderFields=DownloadFiles.cookieHeaders(cookies,for:url);request.setValue(BrowserModel.origin(page).map{$0+"/"},forHTTPHeaderField:"Referer")
        request.setValue(view?.customUserAgent,forHTTPHeaderField:"User-Agent")
        let (file,response)=try await session.download(for:request)
        defer{try? FileManager.default.removeItem(at:file)}
        guard (response as? HTTPURLResponse)?.statusCode==200,response.mimeType?.hasPrefix("image/")==true,(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=33_554_432 else{throw URLError(.cannotDecodeContentData)}
        return try await Task.detached{try Data(contentsOf:file,options:.mappedIfSafe)}.value
    }
}
private final class ComicImageRedirects:NSObject,URLSessionDownloadDelegate,@unchecked Sendable{
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){if totalBytesWritten>33_554_432||totalBytesExpectedToWrite>33_554_432{downloadTask.cancel()}}
    let cookies:[HTTPCookie];let origin:URL
    init(cookies:[HTTPCookie],origin:URL){self.cookies=cookies;self.origin=origin}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
        guard let url=request.url,url.scheme=="https"||url.scheme==origin.scheme,url.host==origin.host else{completionHandler(nil);return}
        var next=request;next.setValue(nil,forHTTPHeaderField:"Cookie");for(k,v)in DownloadFiles.cookieHeaders(cookies,for:url){next.setValue(v,forHTTPHeaderField:k)};completionHandler(next)
    }
}
