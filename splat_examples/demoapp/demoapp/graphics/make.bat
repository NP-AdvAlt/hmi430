@echo off

rem ===========
rem == setup ==
rem ===========

set dst=..\..\..\output
set fontdir=..\..\..\..\..\fonts
set fontmake=..\..\..\..\..\utils\fontmake\Release\fontmake.exe
set difmake=..\..\..\..\..\utils\difmake\Release\difmake.exe -d 565 -o %dst%\
set filesys=..\..\..\..\..\utils\filesys\Release\filesys.exe -o %dst%\filesys.bin

rem == make the output directory if it doesn't exist
if not exist %dst%\ mkdir %dst%
del /q %dst%\*.*


rem ==============
rem == fontmake ==
rem ==============
%fontmake% -s 16 -y -o "%dst%/sysdefault.fon"      "%fontdir%/veramono.ttf"
%fontmake% -s 16 -y -o "%dst%/normalbold.fon"      "%fontdir%/VeraMoBd.ttf"
%fontmake% -s 32 -y -o "%dst%/large.fon"           "%fontdir%/veramono.ttf"
%fontmake% -s 32 -y -o "%dst%/largebold.fon"       "%fontdir%/VeraMoBd.ttf"
%fontmake% -s 7  -y -o "%dst%/small.fon"           "%fontdir%/veramono.ttf"

rem ## Have used this in a number of projects
%fontmake% -s 20    -m "%fontdir%/alpha.txt" -o "%dst%/prop20.fon"       "%fontdir%/MyriadPro-Regular.otf"
rem ## DOM
%fontmake% -s 120 -m "%fontdir%/alpha.txt"   -o "%dst%/mono120.fon"      "%fontdir%/DroidSansMono.ttf"
rem ## seconds
%fontmake% -s 60  -m "%fontdir%/alpha.txt"   -o "%dst%/mono60.fon"       "%fontdir%/DroidSansMono.ttf"
rem ## temperature
%fontmake% -s 50  -m "%fontdir%/alpha.txt"   -o "%dst%/mono50.fon"       "%fontdir%/DroidSansMono.ttf"
rem ## humidity
%fontmake% -s 35  -m "%fontdir%/alpha.txt"   -o "%dst%/mono35.fon"       "%fontdir%/DroidSansMono.ttf"
rem ## hours:min
%fontmake% -s 210 -m "%fontdir%/numbers.txt" -o "%dst%/prop210.fon"      "%fontdir%/MyriadPro-Regular.otf"
rem ## DOW
%fontmake% -s 70  -m "%fontdir%/alpha.txt"   -o "%dst%/prop70.fon"       "%fontdir%/MyriadPro-Regular.otf"
%fontmake% -s 70  -m "%fontdir%/alpha.txt"   -o "%dst%/propbold70.fon"   "%fontdir%/MyriadPro-Bold.otf"
rem ## Month, year, menu
%fontmake% -s 35  -m "%fontdir%/euro.txt"    -o "%dst%/prop35.fon"       "%fontdir%/MyriadPro-Regular.otf"
%fontmake% -s 35  -m "%fontdir%/euro.txt"    -o "%dst%/propbold35.fon"   "%fontdir%/MyriadPro-Bold.otf"
rem ## ordinal suffix
%fontmake% -s 25  -m "%fontdir%/alpha.txt"   -o "%dst%/prop25.fon"       "%fontdir%/MyriadPro-Regular.otf"
rem ## seconds
%fontmake% -s 35  -m "%fontdir%/alpha.txt"   -o "%dst%/ledseg35.fon"     "%fontdir%/Segment14.otf"

rem 24 pixels, so will fit 11.3 lines, useful for real apps
%fontmake% -s 21  -m "%fontdir%/euro.txt" -y -o "%dst%/propnormal.fon"   "%fontdir%/MyriadPro-Regular.otf"


rem =============
rem == difmake ==
rem =============
%difmake%            ..\..\..\graphics\loading.png


rem ===============
rem == filesystem =
rem ===============

rem ------------------
rem -- system files --
rem ------------------
%filesys% -c  -r  "%dst%/sysdefault.fon"
%filesys% -r       "../../../graphics/mtp_icon/mtp.ico"


rem -----------
rem -- fonts --
rem -----------

%filesys%         "%dst%/normalbold.fon"
%filesys%         "%dst%/large.fon"
%filesys%         "%dst%/largebold.fon"
%filesys%         "%dst%/small.fon"
%filesys%         "%dst%/prop20.fon"
%filesys%         "%dst%/mono120.fon"
%filesys%         "%dst%/mono60.fon"
%filesys%         "%dst%/mono50.fon"
%filesys%         "%dst%/mono35.fon"
%filesys%         "%dst%/prop210.fon"
%filesys%         "%dst%/prop70.fon"
%filesys%         "%dst%/propbold70.fon"
%filesys%         "%dst%/prop35.fon"
%filesys%         "%dst%/propbold35.fon"
%filesys%         "%dst%/prop25.fon"
%filesys%         "%dst%/ledseg35.fon"
%filesys%         "%dst%/propnormal.fon"


rem ------------
rem -- images --
rem ------------

rem %filesys%         %dst%/Attention.dif


rem =============
rem == tidy up ==
rem =============

set dst=
set fontdir=
set filesys=
set difmake=
set fontmake=

pause

