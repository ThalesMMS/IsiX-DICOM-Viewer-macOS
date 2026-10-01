#!/usr/bin/env python3
"""Compare real STL/OBJ vertices for asymmetric, transformed surface actors."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
import vtk_pattern_window
install=root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
overlay=(root/'Horos/Sources/SceneOverlay.mm').read_text()
at=overlay.index('std::vector<vtkActor2D *> HorosVisibleActors2D(')
end=overlay.index('\n}\n',at)+3
visible_actors=overlay[at:end]
code=r'''
#include "SRSurfaceExport.h"
#include <vtkAutoInit.h>
#include "vtk_pattern_scene.h"
#include <vtkCellArray.h>
#include <vtkPoints.h>
#include <vtkSTLWriter.h>
#include <vtkSTLReader.h>
#include <vtkOBJExporter.h>
#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkActor2D.h>
#include <vtkActor2DCollection.h>
#include <vtkPropCollection.h>
#include <vtkPropAssembly.h>
#include <vtkNew.h>
#include <vector>
#include <array>
#include <set>
#include <fstream>
#include <sstream>
#include <cassert>
#include <cmath>
VISIBLE_ACTORS
class AggregatedOverlay : public vtkPropAssembly {
public:
 static AggregatedOverlay *New() { return new AggregatedOverlay; }
 vtkActor2D *Actor = nullptr;
 void GetActors2D(vtkPropCollection *collection) override { if(Actor) Actor->GetActors2D(collection); }
};
using Point=std::array<long,3>;
Point key(double x,double y,double z){return {{lround(x*10000),lround(y*10000),lround(z*10000)}};}
int main(int argc,char **argv){
 auto overlayRenderer=vtkSmartPointer<vtkRenderer>::New();
 auto visible=vtkSmartPointer<vtkActor2D>::New();
 auto invisible=vtkSmartPointer<vtkActor2D>::New();invisible->SetVisibility(0);
 auto nested=vtkSmartPointer<vtkActor2D>::New();
 auto assembly=vtkSmartPointer<vtkPropAssembly>::New();assembly->AddPart(nested);
 auto volumeActor=vtkSmartPointer<vtkActor>::New();assembly->AddPart(volumeActor);
 overlayRenderer->AddViewProp(visible);overlayRenderer->AddViewProp(invisible);overlayRenderer->AddViewProp(assembly);
 auto aggregate=vtkSmartPointer<AggregatedOverlay>::New();aggregate->Actor=nested;overlayRenderer->AddViewProp(aggregate);
 auto shown=HorosVisibleActors2D(overlayRenderer);
 assert(shown.size()==2 && shown[0]==visible && shown[1]==nested);
 assert(HorosVisibleActors2D(nullptr).empty());
 nested->SetVisibility(0);shown=HorosVisibleActors2D(overlayRenderer);
 assert(shown.size()==1 && shown[0]==visible);
 auto data=vtkSmartPointer<vtkPolyData>::New();
 auto points=vtkSmartPointer<vtkPoints>::New();
 points->InsertNextPoint(0,0,0);points->InsertNextPoint(2,0,0);points->InsertNextPoint(0,3,0);points->InsertNextPoint(0,0,5);
 auto cells=vtkSmartPointer<vtkCellArray>::New();
 vtkIdType faces[4][3]={{0,2,1},{0,1,3},{1,2,3},{2,0,3}};
 for(auto &face:faces)cells->InsertNextCell(3,face);
 data->SetPoints(points);data->SetPolys(cells);
 auto mapper=vtkSmartPointer<vtkPolyDataMapper>::New();mapper->SetInputData(data);
 auto a=vtkSmartPointer<vtkActor>::New();a->SetMapper(mapper);a->SetOrigin(1,2,3);a->RotateZ(90);a->SetPosition(-40,-20,-10);
 auto b=vtkSmartPointer<vtkActor>::New();b->SetMapper(mapper);b->SetScale(2,3,1);b->SetPosition(-70,-50,-30);
 auto user=vtkSmartPointer<vtkTransform>::New();user->RotateX(30);b->SetUserTransform(user);
 auto hidden=vtkSmartPointer<vtkActor>::New();hidden->SetMapper(mapper);hidden->SetVisibility(0);
 vtkActor *actors[]={a,b,hidden,nullptr};
 auto geometry=HorosSurfaceExportGeometry(actors,4);
 assert(geometry->GetNumberOfPolys()==8);
 auto renderer=vtkSmartPointer<vtkRenderer>::New();renderer->AddActor(a);renderer->AddActor(b);renderer->AddActor(hidden);
 auto window=vtkSmartPointer<vtkRenderWindow>::New();window->AddRenderer(renderer);
 std::string prefix=argv[1],stl=prefix+".stl";
 auto sw=vtkSmartPointer<vtkSTLWriter>::New();sw->SetInputData(geometry);sw->SetFileName(stl.c_str());sw->Write();
 auto ow=vtkSmartPointer<vtkOBJExporter>::New();ow->SetRenderWindow(window);ow->SetFilePrefix(prefix.c_str());ow->Write();
 std::set<Point> objVertices,stlVertices,expected;
 std::ifstream in(prefix+".obj");std::string line;
 while(std::getline(in,line)){std::istringstream row(line);std::string tag;double x,y,z;row>>tag;if(tag=="v" && row>>x>>y>>z)objVertices.insert(key(x,y,z));}
 auto reader=vtkSmartPointer<vtkSTLReader>::New();reader->SetFileName(stl.c_str());reader->Update();
 assert(reader->GetOutput()->GetNumberOfPolys()==8);
 for(vtkIdType i=0;i<reader->GetOutput()->GetNumberOfPoints();i++){auto p=reader->GetOutput()->GetPoint(i);stlVertices.insert(key(p[0],p[1],p[2]));}
 for(auto actor:{a,b})for(int i=0;i<4;i++){double p[4],q[4];points->GetPoint(i,p);p[3]=1;actor->GetMatrix()->MultiplyPoint(p,q);expected.insert(key(q[0],q[1],q[2]));}
 assert(expected.size()==8 && objVertices==expected && stlVertices==expected);
 assert((*stlVertices.begin())[0]<0);
 assert(HorosSurfaceExportGeometry(nullptr,0)->GetNumberOfPoints()==0);
 b->SetVisibility(0);assert(HorosSurfaceExportGeometry(actors,4)->GetNumberOfPolys()==4);
 double original[3];points->GetPoint(0,original);assert(original[0]==0 && original[1]==0 && original[2]==0);
 puts("PASS: STL and OBJ preserve both asymmetric actors, negative coordinates, origin/rotation/scale/user transform; hidden actors excluded and source unmodified");
}
'''.replace('VISIBLE_ACTORS',visible_actors)
with tempfile.TemporaryDirectory(prefix='horos-surface-export-') as folder:
 p=Path(folder);(p/'test.cpp').write_text(code);(p/'vtk_pattern_scene.h').write_text(vtk_pattern_window.WINDOW+vtk_pattern_window.SCENE)
 # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
 libs = [install / 'wlib' / 'libVTK.a']
 subprocess.run(['xcrun','clang++','-std=c++17','-Werror=deprecated-declarations','-fsanitize=address','-I'+str(install/'include'),'-I'+str(root/'Horos/Sources'),str(p/'test.cpp'),str(root/'Horos/Sources/SceneFactory.cxx'),*[str(x) for x in libs],'-L'+str(install.parent.parent/'ExternalInputs.build/Install/lib'),'-lpng16','-ltiff','-lz','-framework','Cocoa','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'model')],check=True)
