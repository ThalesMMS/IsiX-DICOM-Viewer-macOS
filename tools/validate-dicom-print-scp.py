#!/usr/bin/env python3
"""Exercise bundled DCMTK printing against a loopback-only synthetic Print SCP."""
import argparse
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import numpy as np
from pydicom.dataset import Dataset
from pydicom.uid import generate_uid, ImplicitVRLittleEndian
from pynetdicom import AE, evt
from pynetdicom.sop_class import BasicGrayscalePrintManagementMeta, BasicFilmBox, BasicGrayscaleImageBox, Verification
from pynetdicom.pdu import A_RELEASE_RQ

ROOT = Path(__file__).resolve().parent.parent

def config_template():
    """Evaluate the production literal with Swift's multiline-string semantics."""
    source=(ROOT/'DICOMPrint/AYDicomPrintWindowController.swift').read_text(encoding='utf-8')
    declaration=re.search(r'^private let DCMTK_PRINTER_CONFIG_TEMPLATE = """\n.*?^[ \t]*"""',source,re.M|re.S)
    if declaration is None:
        raise ValueError('Production Swift printer configuration literal not found')
    program=('import Foundation\n'+declaration.group(0)+
             '\nFileHandle.standardOutput.write(Data(DCMTK_PRINTER_CONFIG_TEMPLATE.utf8))\n')
    result=subprocess.run(['xcrun','swift','-'],input=program,text=True,
                          capture_output=True,check=True,timeout=60)
    return result.stdout

def capture_server(columns,rows,reject="",port=0,output=None):
    captured={'film_boxes':[],'images':[],'actions':0,'associations':[],'film_sessions':[]}
    boxes={}
    def accepted(event):
        captured['associations'].append([{'abstract_syntax':str(context.abstract_syntax), 'transfer_syntax':[str(syntax) for syntax in context.transfer_syntax]} for context in event.assoc.accepted_contexts])
        if output: (output/'received.json').write_text(json.dumps(captured,indent=2))
    def create(event):
        data=event.attribute_list
        response=Dataset();response.AffectedSOPInstanceUID=generate_uid()
        if event.request.AffectedSOPClassUID==BasicFilmBox:
            captured['film_boxes'].append({key:str(data.get(key,'')) for key in ['ImageDisplayFormat','FilmSizeID','FilmOrientation','MagnificationType']})
            if output: (output/'received.json').write_text(json.dumps(captured,indent=2))
            if reject=='film': return 0x0106,None
            refs=[]
            for position in range(1,columns*rows+1):
                ref=Dataset();ref.ReferencedSOPClassUID=BasicGrayscaleImageBox;ref.ReferencedSOPInstanceUID=generate_uid();boxes[str(ref.ReferencedSOPInstanceUID)]=position;refs.append(ref)
            response.ReferencedImageBoxSequence=refs
        else:
            captured['film_sessions'].append({key:str(data.get(key,'')) for key in ['NumberOfCopies','PrintPriority','MediumType','FilmDestination']})
        return 0x0000,response
    def set_image(event):
        data=event.modification_list
        pixel=data.BasicGrayscaleImageSequence[0]
        dtype='<u2' if pixel.BitsAllocated==16 else 'u1'
        array=np.frombuffer(pixel.PixelData,dtype=dtype).reshape(int(pixel.Rows),int(pixel.Columns))
        captured['images'].append({'position':int(data.ImageBoxPosition),'referenced_position':boxes[str(event.request.RequestedSOPInstanceUID)],'rows':int(pixel.Rows),'columns':int(pixel.Columns),'bits':int(pixel.BitsStored),'sample':int(array[8,8]),'minimum':int(array.min()),'maximum':int(array.max()),'top_left':int(array[1,1]),'bottom_right':int(array[-2,-2])})
        if output:
            np.save(output/f'image-{len(captured["images"]):03d}.npy',array)
            (output/'received.json').write_text(json.dumps(captured,indent=2))
        return (0xC605 if reject=='image' else 0x0000),None
    def action(event):
        captured['actions']+=1
        if output: (output/'received.json').write_text(json.dumps(captured,indent=2))
        return (0xC600 if reject=='action' else 0xB600 if reject=='warning' else 0x0000),None
    def receive_pdu(event):
        if reject=='release' and isinstance(event.pdu,A_RELEASE_RQ):
            event.assoc.abort(block=False)
    def get_printer(event):
        data=Dataset();data.PrinterStatus='NORMAL';data.PrinterStatusInfo='NORMAL';data.PrinterName='LOOPBACK QA'
        return 0x0000,data
    ae=AE(ae_title='PRINTQA')
    if reject!='negotiation': ae.add_supported_context(BasicGrayscalePrintManagementMeta,[ImplicitVRLittleEndian])
    ae.add_supported_context(Verification,[ImplicitVRLittleEndian])
    server=ae.start_server(('127.0.0.1',port),block=False,evt_handlers=[(evt.EVT_ACCEPTED,accepted),(evt.EVT_C_ECHO,lambda event:0x0000),(evt.EVT_N_CREATE,create),(evt.EVT_N_SET,set_image),(evt.EVT_N_ACTION,action),(evt.EVT_N_GET,get_printer),(evt.EVT_N_DELETE,lambda event:0x0000),(evt.EVT_PDU_RECV,receive_pdu)])
    return server,captured

def validate(resources, output, sender='HorosStoredPrint'):
    template=config_template()
    output.mkdir(parents=True,exist_ok=True)
    if any(output.iterdir()): raise ValueError('Use an empty output directory')
    resources=resources.resolve();output=output.resolve()
    fixture=runpy.run_path(str(ROOT/'tools/generate-jpeg-series-fixture.py'))
    env=os.environ.copy();env['DCMDICTPATH']=str(resources/'dicom.dic')
    results=[]
    cases=[(6,4,''),(6,5,''),(6,5,'film'),(6,5,'image'),(6,5,'action')]
    if sender=='HorosStoredPrint': cases += [(6,4,'warning'),(6,4,'release'),(6,4,'negotiation'),(6,4,'batch')]
    for columns,rows,reject in cases:
        name=f'{columns}x{rows}'+('-rejected-'+reject if reject else '')
        job=output/name;job.mkdir();(job/'database').mkdir()
        server,captured=capture_server(columns,rows,reject)
        try:
            values={'PRINTER_AETITLE':'PRINTQA','HOST':'127.0.0.1','PORT':str(server.server_address[1]),'HOROS_AETITLE':'HOROSQA','COLUMNS':str(columns),'ROWS':str(rows),'FILM_DESTINATION':'PROCESSOR','FILM_SIZE':'14INX17IN','MEDIUM_TYPE':'PAPER','MAGNIFICATION_TYPE':'BILINEAR'}
            config=template
            for key,value in values.items():config=config.replace('{{'+key+'}}',value)
            (job/'print.cfg').write_text(config)
            images=[]
            for index in range(columns*rows):
                path=job/f'image-{index+1:02d}.dcm';ds=fixture['dataset'](path,f'print-{name}-{index}',False)
                ds.PatientName='QA^Print';ds.PatientID='LOCAL-PRINT-QA';ds.Rows=32;ds.Columns=64;ds.InstanceNumber=index+1
                # DCMTK renders through 12-bit hardcopy and truncates back to 8-bit.
                # Center the fixture levels in output bins to preserve exact ordinals.
                ds.WindowCenter=127.5
                # The center patch encodes ordinal; asymmetric markers reveal orientation.
                pixels=np.full((32,64),20+index*5,dtype=np.uint8);pixels[0:4,0:4]=0;pixels[-4:,-4:]=255
                segments={'0':'abcdef','1':'bc','2':'abged','3':'abgcd','4':'fgbc','5':'afgcd','6':'afgecd','7':'abc','8':'abcdefg','9':'abfgcd'}
                for digit_index,digit in enumerate(f'{index+1:02d}'):
                    x=30+digit_index*12;y=7
                    bars={'a':(0,0,2,8),'b':(0,6,9,2),'c':(8,6,9,2),'d':(15,0,2,8),'e':(8,0,9,2),'f':(0,0,9,2),'g':(7,0,2,8)}
                    for segment in segments[digit]:
                        dy,dx,h,w=bars[segment];pixels[y+dy:y+dy+h,x+dx:x+dx+w]=255
                ds.PixelData=pixels.tobytes();ds.save_as(path,enforce_file_format=True);images.append(str(path))
            prep=[str(resources/'dcmpsprt'),'-c','print.cfg','--printer','PRINTSCP','--layout',str(columns),str(rows),'--filmsize','14INX17IN','--magnification','BILINEAR','--border','BLACK','--empty-image','BLACK','--no-trim','--portrait',*images]
            with (job/'prepare.log').open('w') as log:subprocess.run(prep,cwd=job,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
            states=sorted((job/'database').glob('SP_*'));assert len(states)==1,states
            # An operation/release failure in the first file must stop the batch.
            if sender=='HorosStoredPrint' and reject in ('film','image','action','release','negotiation','batch'):
                second=job/'database/SP_second';second.write_bytes(states[0].read_bytes());states.append(second)
            send=[str(resources/sender),'-c','print.cfg','--printer','PRINTSCP','--copies','1','--priority','MED','--destination','PROCESSOR','--medium-type','PAPER',*[str(p) for p in states]]
            with (job/'send.log').open('w') as log:process=subprocess.run(send,cwd=job,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60)
            captured['exit_status']=process.returncode
            (job/'received.json').write_text(json.dumps(captured,indent=2))
            if reject=='negotiation':
                assert process.returncode!=0 and not captured['film_sessions'] and not captured['actions'],captured
                results.append({'case':name,**captured});print('PASS:',name,'exit',process.returncode)
                continue
            pages=2 if reject=='batch' else 1
            assert captured['associations']==[[{'abstract_syntax':str(BasicGrayscalePrintManagementMeta),'transfer_syntax':[str(ImplicitVRLittleEndian)]}]]*pages,captured
            assert captured['film_sessions']==[{'NumberOfCopies':'1','PrintPriority':'MED','MediumType':'PAPER','FilmDestination':'PROCESSOR'}]*pages,captured
            assert captured['film_boxes'],captured
            film=captured['film_boxes'][0]
            assert film['ImageDisplayFormat']==f'STANDARD\\{columns},{rows}',film
            assert film['FilmSizeID']=='14INX17IN' and film['FilmOrientation']=='PORTRAIT',film
            if reject and reject not in ('warning','batch'):
                assert process.returncode!=0,captured
                if reject=='film': assert not captured['images'] and not captured['actions'],captured
                if reject=='image': assert len(captured['images'])==1 and not captured['actions'],captured
                if reject=='action': assert len(captured['images'])==columns*rows and captured['actions']==1,captured
                if reject=='release':
                    assert len(captured['images'])==columns*rows and captured['actions']==1,captured
                    log=(job/'send.log').read_text()
                    assert 'operation=0 cleanup=0 release=1 accepted=1' in log,log
            else:
                assert process.returncode==0 and len(captured['images'])==columns*rows*pages and captured['actions']==pages,captured
                for index,image in enumerate(captured['images']):
                    ordinal=index%(columns*rows)
                    assert image['position']==image['referenced_position']==ordinal+1,image
                    assert (image['rows'],image['columns'])==(32,64),image
                    assert image['sample']==20+ordinal*5 and image['top_left']==0 and image['bottom_right']==255,image
                samples=[x['sample'] for x in captured['images'][:columns*rows]]
                assert all(a<b for a,b in zip(samples,samples[1:])),samples
            (job/'received.json').write_text(json.dumps(captured,indent=2))
            results.append({'case':name,**captured})
            print('PASS:',name,'images',len(captured['images']),'exit',process.returncode)
        finally:
            server.shutdown()
    if sender=='HorosStoredPrint':
        job=output/'6x4'
        base=[str(resources/sender),'-c','print.cfg','--printer','PRINTSCP']
        for name,files in [('empty',[]),('missing',['missing.dcm']),('invalid',['print.cfg'])]:
            result=subprocess.run(base+files,cwd=job,env=env,capture_output=True,text=True,timeout=60)
            assert result.returncode!=0,(name,result)
            results.append({'case':name,'exit_status':result.returncode})
            print('PASS:',name,'exit',result.returncode)
    (output/'summary.json').write_text(json.dumps(results,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('resources',type=Path)
    parser.add_argument('output',type=Path)
    parser.add_argument('--sender',choices=['HorosStoredPrint','dcmprscu'],default='HorosStoredPrint',help='Native helper, or upstream client for a baseline run')
    parser.add_argument('--serve',action='store_true',help='Listen for the native Horos print UI until interrupted')
    parser.add_argument('--port',type=int,default=15962)
    parser.add_argument('--columns',type=int,default=2)
    parser.add_argument('--rows',type=int,default=2)
    parser.add_argument('--reject', choices=['film','image','action'], default='', help='Reject one protocol stage in native serve mode')
    args=parser.parse_args()
    if args.serve:
        import time
        args.output.mkdir(parents=True,exist_ok=True)
        if any(args.output.iterdir()): raise ValueError('Use an empty output directory')
        server,captured=capture_server(args.columns,args.rows,reject=args.reject,port=args.port,output=args.output)
        print(f'Print SCP listening only on 127.0.0.1:{args.port}',flush=True)
        try:
            while True: time.sleep(1)
        except KeyboardInterrupt: pass
        finally: server.shutdown()
    else: validate(args.resources,args.output,args.sender)
