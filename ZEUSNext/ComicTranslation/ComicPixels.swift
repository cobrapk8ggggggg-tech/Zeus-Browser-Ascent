import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UIKit
import ZeusComicRuntime

enum ComicPixels {
    static func context(width:Int,height:Int)->CGContext?{CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)}
    static func rgba(_ image:CGImage,width:Int,height:Int)->[UInt8]?{guard let c=context(width:width,height:height)else{return nil};c.interpolationQuality = .high;c.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return c.data.map{Array(UnsafeBufferPointer(start:$0.assumingMemoryBound(to:UInt8.self),count:width*height*4))}}
    static func rotated(_ image:CGImage)->CGImage{guard let c=context(width:image.height,height:image.width)else{return image};c.translateBy(x:CGFloat(image.height),y:0);c.rotate(by:.pi/2);c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return c.makeImage() ?? image}
    static func decode(_ data:Data)throws->CGImage{guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false]as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth]as? Int,let height=properties[kCGImagePropertyPixelHeight]as? Int,width>0,height>0,width<=16_384,Int64(width)*Int64(height)<=16_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true]as CFDictionary)else{throw ComicFailure.message("تعذّر فك الصورة ضمن حد الذاكرة؛ لم تُخفض دقتها بصمت.")};return image}
    static func decodeRegion(_ data:Data,region:ComicRegion,expectedHeight:Int?=nil)throws->CGImage{
        if let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false]as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as? [CFString:Any]{
            let width=(properties[kCGImagePropertyPixelWidth]as? NSNumber)?.intValue,height=(properties[kCGImagePropertyPixelHeight]as? NSNumber)?.intValue
            guard width==region.width,expectedHeight==nil||height==expectedHeight else{throw ComicFailure.message("تغيرت أبعاد الصورة؛ لم تُستخدم إحداثيات لا تطابق الأصل.")}
        }
        let pointer=data.withUnsafeBytes{buffer in zeus_comic_decode_region(buffer.bindMemory(to:UInt8.self).baseAddress,UInt(data.count),Int32(region.x),Int32(region.y),Int32(region.width),Int32(region.height))}
        if let pointer{
            let pixels=Data(bytesNoCopy:pointer,count:region.width*region.height*4,deallocator:.custom{p,_ in zeus_comic_free_pixels(p.assumingMemoryBound(to:UInt8.self))})
            guard let provider=CGDataProvider(data:pixels as CFData),let result=CGImage(width:region.width,height:region.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:region.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)else{throw ComicFailure.message("فشل إنشاء منطقة الصورة.")};return result
        }
        let image=try decode(data);guard image.width==region.width,expectedHeight==nil||image.height==expectedHeight,let crop=image.cropping(to:region.rect)else{throw ComicFailure.message("تعذّر فك المنطقة المطلوبة.")};return crop
    }
    static func png(_ image:CGImage)throws->Data{let output=NSMutableData();guard let destination=CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil)else{throw ComicFailure.message("تعذّر ترميز الصورة.")};CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination)else{throw ComicFailure.message("فشل ترميز الصورة.")};return output as Data}
    static func render(_ image:CGImage,speeches:[ComicSpeech],translations:[TranslationSegment],target:String,fontName:String?,fontScale:Double,textColor:String? = nil)throws->CGImage{
        guard let context=context(width:image.width,height:image.height),let pixels=rgba(image,width:image.width,height:image.height)else{throw ComicFailure.message("ذاكرة غير كافية للرسم.")}
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let translated=Dictionary(uniqueKeysWithValues:translations.map{($0.id,$0.text)})
        // CG image coordinates are top-left. CoreGraphics/CoreText are bottom-left.
        for speech in speeches {
            guard let text=translated[speech.id],!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{continue}
            let pad=speech.balloon ? 0:max(2,min(speech.rect.width,speech.rect.height)*0.08)
            let area=speech.rect.insetBy(dx:-pad,dy:-pad).intersection(CGRect(x:0,y:0,width:image.width,height:image.height)).integral
            guard area.width>3,area.height>3 else{continue}
            let background=backgroundColor(pixels,width:image.width,height:image.height,rect:area,excluding:speech.lines.map(\.rect))
            // Prepare layout before erasing any source text. Failed fit leaves the original.
            guard let layout=layout(text,rect:area.insetBy(dx:2,dy:2),target:target,fontName:fontName,fontScale:fontScale)else{throw ComicFailure.message("لم يتسع النص للفقاعة؛ بقي الأصل دون مسح.")}
            // Erase foreground components only inside detected source lines. Uniform
            // fills are confined to the text masks; balloon borders remain untouched.
            clean(context,pixels:pixels,width:image.width,height:image.height,speech:speech,background:background)
            let automatic=automaticInk(background)
            let color=textColor.flatMap(Self.color) ?? automatic
            context.saveGState();context.setFillColor(color);context.textMatrix = .identity
            let box=CGRect(x:area.minX+2,y:CGFloat(image.height)-area.maxY+2+(area.height-4-layout.height)/2,width:area.width-4,height:layout.height)
            let attributed=NSMutableAttributedString(attributedString:layout.text);attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),value:color,range:NSRange(location:0,length:attributed.length))
            let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),CFRange(),CGPath(rect:box,transform:nil),nil);CTFrameDraw(frame,context);context.restoreGState()
        }
        guard let result=context.makeImage()else{throw ComicFailure.message("فشل رسم النص.")};return result
    }
    static func color(_ hex:String)->CGColor?{let value=hex.replacingOccurrences(of:"#",with:"");guard value.count==6,let n=UInt32(value,radix:16)else{return nil};return CGColor(red:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)}
    struct TextLayout{var text:NSAttributedString;var height:CGFloat;var size:CGFloat}
    static func layout(_ text:String,rect:CGRect,target:String,fontName:String?,fontScale:Double)->TextLayout?{
        guard rect.width>2,rect.height>2 else{return nil}
        let style=NSMutableParagraphStyle();style.alignment = .center;style.baseWritingDirection=TranslationPreferences.rtl(target) ? .rightToLeft:.leftToRight;style.lineBreakMode = .byWordWrapping
        var low:CGFloat=6,high=min(96,rect.height),best:TextLayout?
        for _ in 0..<9{let size=(low+high)/2,font=CTFontCreateWithName((fontName ?? (TranslationPreferences.rtl(target) ? "GeezaPro":"ArialMT"))as CFString,size,nil)
            let value=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,.paragraphStyle:style])
            let setter=CTFramesetterCreateWithAttributedString(value);var fit=CFRange();let measured=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(),nil,CGSize(width:rect.width,height:CGFloat.greatestFiniteMagnitude),&fit)
            if measured.height<=rect.height && measured.width<=rect.width+0.5 && fit.length==value.length{best=TextLayout(text:value,height:ceil(measured.height),size:size);low=size}else{high=size}
        }
        guard let best else{return nil}
        let chosen=min(best.size,max(6,best.size*CGFloat(min(1.5,max(0.5,fontScale)))*0.8))
        let font=CTFontCreateWithName((fontName ?? (TranslationPreferences.rtl(target) ? "GeezaPro":"ArialMT"))as CFString,chosen,nil)
        let text=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,.paragraphStyle:style])
        let measured=CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text),CFRange(),nil,CGSize(width:rect.width,height:CGFloat.greatestFiniteMagnitude),nil)
        return TextLayout(text:text,height:ceil(measured.height),size:chosen)
    }
    static func automaticInk(_ background:(CGFloat,CGFloat,CGFloat))->CGColor {
        func linear(_ c:CGFloat)->CGFloat { c<=0.04045 ? c/12.92:pow((c+0.055)/1.055,2.4) }
        let luminance=0.2126*linear(background.0)+0.7152*linear(background.1)+0.0722*linear(background.2)
        let black=(luminance+0.05)/(linear(0.04)+0.05)
        let white=(linear(0.98)+0.05)/(luminance+0.05)
        return black>=white ? CGColor(gray:0.04,alpha:1):CGColor(gray:0.98,alpha:1)
    }
    static func backgroundColor(_ pixels:[UInt8],width:Int,height:Int,rect:CGRect,excluding:[CGRect]=[])->(CGFloat,CGFloat,CGFloat){
        var bins:[Int:(Int,Int,Int,Int)]=[:]
        let x0=max(0,Int(rect.minX)-3),x1=min(width-1,Int(rect.maxX)+3),y0=max(0,Int(rect.minY)-3),y1=min(height-1,Int(rect.maxY)+3)
        guard x1>=x0,y1>=y0 else{return(1,1,1)}
        func sample(_ x:Int,_ y:Int) {
            let i=(y*width+x)*4,r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2])
            let key=(r/32)*64+(g/32)*8+b/32,old=bins[key] ?? (0,0,0,0)
            bins[key]=(old.0+r,old.1+g,old.2+b,old.3+1)
        }
        // Sample the inside of the balloon, excluding source glyph boxes. A
        // dark outline or textured panel outside the balloon must not set its fill.
        let inside=rect.insetBy(dx:rect.width*0.12,dy:rect.height*0.12).integral
        let strideSize=max(1,Int(sqrt(max(1,inside.width*inside.height)/4096)))
        for y in stride(from:max(0,Int(inside.minY)),to:min(height,Int(inside.maxY)),by:strideSize) {
            for x in stride(from:max(0,Int(inside.minX)),to:min(width,Int(inside.maxX)),by:strideSize) {
                if !excluding.contains(where:{$0.insetBy(dx:-2,dy:-2).contains(CGPoint(x:x,y:y))}) { sample(x,y) }
            }
        }
        if bins.isEmpty {
            for y in y0...y1{for x in x0...x1 where x<x0+3||x>x1-3||y<y0+3||y>y1-3{sample(x,y)}}
        }
        guard let value=bins.values.max(by:{$0.3<$1.3}),value.3>0 else{return(1,1,1)}
        return(CGFloat(value.0)/CGFloat(value.3*255),CGFloat(value.1)/CGFloat(value.3*255),CGFloat(value.2)/CGFloat(value.3*255))
    }
    private static func clean(_ context:CGContext,pixels:[UInt8],width:Int,height:Int,speech:ComicSpeech,background:(CGFloat,CGFloat,CGFloat)){
        let color=CGColor(red:background.0,green:background.1,blue:background.2,alpha:1);context.setFillColor(color)
        for line in speech.lines{
            let box=line.rect.insetBy(dx:-1,dy:-1).integral.intersection(CGRect(x:0,y:0,width:width,height:height));guard !box.isNull else{continue}
            for y in Int(box.minY)..<Int(box.maxY){var start:Int?
                for x in Int(box.minX)..<Int(box.maxX){let i=(y*width+x)*4;let distance=abs(CGFloat(pixels[i])/255-background.0)+abs(CGFloat(pixels[i+1])/255-background.1)+abs(CGFloat(pixels[i+2])/255-background.2)
                    if distance>0.3{if start==nil{start=x}}else if let begin=start{context.fill(CGRect(x:max(Int(box.minX),begin-1),y:height-y-2,width:x-begin+2,height:3));start=nil}
                };if let begin=start{context.fill(CGRect(x:begin,y:height-y-2,width:Int(box.maxX)-begin,height:3))}
            }
        }
    }
}
