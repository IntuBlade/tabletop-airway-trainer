#import "FixtureReader.h"
#import <opencv2/calib3d.hpp>
#import <opencv2/objdetect/aruco_detector.hpp>
#import <opencv2/imgproc.hpp>
#include <map>
using namespace cv;
namespace {
struct Mark { bool moving; std::vector<Point3d> corners; };
struct Seen { const Mark *mark; std::vector<Point2f> uv; };
struct Fit { Vec3d rot, trans; double travel=0, error=1e9; };
Vec3d vec(NSArray *a){return { [a[0] doubleValue],[a[1] doubleValue],[a[2] doubleValue] };}
NSArray *list(Vec3d v){return @[@(v[0]),@(v[1]),@(v[2])];}
Matx33d rotation(const Fit &p){Matx33d r;Rodrigues(p.rot,r);return r;}
double refine(Fit &p,const std::vector<Seen>& marks,Matx33d K,bool joint){
    const int dim=joint?7:6;
    for(int iter=0;iter<24;iter++){
        std::vector<Point3d> points;std::vector<Point2f> observed;std::vector<bool> moving;
        for(auto &s:marks) for(int k=0;k<4;k++){
            auto pt=s.mark->corners[k];if(s.mark->moving)pt.z+=p.travel;
            points.push_back(pt);observed.push_back(s.uv[k]);moving.push_back(s.mark->moving);
        }
        std::vector<Point2d> uv;Mat J;
        projectPoints(points,p.rot,p.trans,K,noArray(),uv,J);
        Mat A=Mat::zeros(2*points.size(),dim,CV_64F),d(A.rows,1,CV_64F);
        Matx33d R=rotation(p);double sq=0;
        for(int i=0;i<(int)uv.size();i++){
            if((R*Vec3d(points[i])+p.trans)[2]<=.1)return 1e9;
            for(int j=0;j<2;j++){
                int n=2*i+j;double e=j?observed[i].y-uv[i].y:observed[i].x-uv[i].x;
                sq+=e*e;double w=1/sqrt(std::max(1.,fabs(e)));
                for(int k=0;k<6;k++)A.at<double>(n,k)=J.at<double>(n,k)*w;
                if(joint && moving[i])for(int k=0;k<3;k++)A.at<double>(n,6)+=J.at<double>(n,3+k)*R(k,2)*w;
                d.at<double>(n)=w*e;
            }
        }
        p.error=sqrt(sq/A.rows);
        Mat step;if(!solve(A,d,step,DECOMP_SVD))return 1e9;
        if(norm(step)<1e-6 || iter==23)return p.error;
        if(norm(step)>160)return 1e9;
        for(int k=0;k<3;k++){p.rot[k]+=step.at<double>(k);p.trans[k]+=step.at<double>(3+k);}
        if(joint)p.travel+=step.at<double>(6);
    }
    return p.error;
}
}
@implementation FixtureReader {
    std::map<int,Mark> _map;
    std::unique_ptr<aruco::ArucoDetector> _detector;
    Fit _previous;bool _hasPrevious,_screen;
}
-(instancetype)initWithMap:(NSURL *)url {
    if(!(self=[super init]))return nil;
    NSData *data=[NSData dataWithContentsOfURL:url];if(!data)return nil;
    NSArray *rows=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    for(NSDictionary *r in rows){
        Vec3d c=vec(r[@"center"]),u=vec(r[@"right"]),v=vec(r[@"up"]);double h=[r[@"width"] doubleValue]/2;
        _map[[r[@"id"] intValue]]={ [r[@"moving"] boolValue]!=NO,{Point3d(c+h*(-u+v)),Point3d(c+h*(u+v)),Point3d(c+h*(u-v)),Point3d(c+h*(-u-v))} };
    }
    aruco::DetectorParameters par;par.cornerRefinementMethod=aruco::CORNER_REFINE_SUBPIX;par.cornerRefinementWinSize=3;par.minDistanceToBorder=1;
    _detector=std::make_unique<aruco::ArucoDetector>(aruco::getPredefinedDictionary(aruco::DICT_4X4_250),par);
    return self;
}
-(NSDictionary *)readImage:(CGImageRef)image horizontalField:(double)field {
    NSDictionary *empty=@{@"walls":@0,@"sliders":@0};
    try {
        int w=640,h=std::max(1,(int)lround(640.*CGImageGetHeight(image)/CGImageGetWidth(image)));
        Mat gray(h,w,CV_8U);CGColorSpaceRef cs=CGColorSpaceCreateDeviceGray();
        CGContextRef ctx=CGBitmapContextCreate(gray.data,w,h,8,gray.step,cs,kCGImageAlphaNone);CGColorSpaceRelease(cs);
        if(!ctx){_hasPrevious=false;return empty;}
        CGContextDrawImage(ctx,CGRectMake(0,0,w,h),image);CGContextRelease(ctx);
        std::vector<int> ids;std::vector<std::vector<Point2f>> squares;_detector->detectMarkers(gray,squares,ids);
        std::vector<Seen> all,fixed;bool screen=false,fixture=false;
        for(size_t i=0;i<ids.size();i++){
            auto it=_map.find(ids[i]);if(it==_map.end())continue;
            screen|=ids[i]>=240;fixture|=ids[i]<240;
            all.push_back({&it->second,squares[i]});if(!it->second.moving)fixed.push_back(all.back());
        }
        NSMutableDictionary *result=[@{@"walls":@(fixed.size()),@"sliders":@(all.size()-fixed.size()),@"screen":@(screen)} mutableCopy];
        if(fixed.empty() || (screen && fixture)){_hasPrevious=false;return result;}
        if(_screen!=screen)_hasPrevious=false;_screen=screen;
        double focal=w/2./tan(field*CV_PI/360.);Matx33d K(focal,0,w/2.,0,focal,h/2.,0,0,1);
        std::vector<Fit> seeds;if(_hasPrevious)seeds.push_back(_previous);
        std::sort(fixed.begin(),fixed.end(),[](auto &a,auto &b){return norm(a.uv[0]-a.uv[2])>norm(b.uv[0]-b.uv[2]);});
        for(size_t i=0;i<std::min<size_t>(3,fixed.size());i++){
            std::vector<Mat> rv,tv;std::vector<Point2d> q(fixed[i].uv.begin(),fixed[i].uv.end());
            solvePnPGeneric(fixed[i].mark->corners,q,K,noArray(),rv,tv,false,SOLVEPNP_IPPE);
            for(size_t k=0;k<rv.size();k++)seeds.push_back({Vec3d(rv[k]),Vec3d(tv[k])});
        }
        for(bool joint:{true,false}){
            if(joint && all.size()==fixed.size())continue;
            std::vector<Fit> good;
            for(auto p:seeds){
                if(!joint)p.travel=0;
                double e=refine(p,joint?all:fixed,K,joint);
                if(e<=2.5 && (!joint || fabs(p.travel)<=9))good.push_back(p);
            }
            if(good.empty())continue;
            auto best=std::min_element(good.begin(),good.end(),[](auto &a,auto &b){return a.error<b.error;});
            if(_hasPrevious){
                double limit=best->error+.10,nearest=1e9;
                for(auto it=good.begin();it!=good.end();++it)if(it->error<=limit){
                    double turn=norm(Mat(rotation(*it)-rotation(_previous)));
                    if(turn<nearest){nearest=turn;best=it;}
                }
            }
            _previous=*best;_hasPrevious=true;auto R=rotation(*best).t();
            result[@"lens"]=list(-(R*best->trans));result[@"right"]=list(R*Vec3d(1,0,0));result[@"up"]=list(R*Vec3d(0,-1,0));result[@"forward"]=list(R*Vec3d(0,0,1));
            if(joint)result[@"lift"]=@(asin(best->travel/9)*180/CV_PI);
            return result;
        }
    } catch(const cv::Exception &){ }
    _hasPrevious=false;return empty;
}
@end
