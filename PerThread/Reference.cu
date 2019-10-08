#include <iostream>
#include <iomanip>
#include <vector>
#include <string>
#include <fstream>

#define F(i)    F[tid + i*NT]
#define X(i)    X[tid + i*NT]
#define cPAR(i) cPAR[tid + i*NT]
#define sPAR(i) sPAR[i]
#define ACC(i)  ACC[tid + i*NT]
#define EF(i)   EF[tid + i*NT]
#define TD(i)   TD[tid + i*NT]
	#include "PerThread_SystemDefinition.cuh"
#undef F
#undef X
#undef cPAR
#undef sPAR
#undef ACC
#undef EF
#undef TD

#include "MassivelyParallel_GPU-ODE_Solver.cuh"

#define PI 3.14159265358979323846

using namespace std;

void Linspace(vector<double>&, double, double, int);
void FillSolverObject(ProblemSolver&, const vector<double>&, double, double, double, int, int);
void SaveData(ProblemSolver&, ofstream&, int);

int main()
{
// INITIAL SETUP ----------------------------------------------------------------------------------
	
	int NumberOfProblems = 46080;
	int NumberOfThreads  = 23040;
	int BlockSize        = 64;
	
	ListCUDADevices();
	
	int MajorRevision  = 3;
	int MinorRevision  = 5;
	int SelectedDevice = SelectDeviceByClosestRevision(MajorRevision, MinorRevision);
	
	PrintPropertiesOfSpecificDevice(SelectedDevice);
	
	
	double InitialConditions_X1 = -0.5;
	double InitialConditions_X2 = -0.1;
	double Parameters_B = 0.3;
	
	int NumberOfParameters_k = NumberOfProblems;
	double kRangeLower = 0.2;
    double kRangeUpper = 0.3;
		vector<double> Parameters_k_Values(NumberOfParameters_k,0);
		Linspace(Parameters_k_Values, kRangeLower, kRangeUpper, NumberOfParameters_k);
	
	
	ConstructorConfiguration ConfigurationDuffing;
	
	ConfigurationDuffing.NumberOfThreads           = NumberOfThreads;
	ConfigurationDuffing.SystemDimension           = 2;
	ConfigurationDuffing.NumberOfControlParameters = 1;
	ConfigurationDuffing.NumberOfSharedParameters  = 1;
	ConfigurationDuffing.NumberOfEvents            = 2;
	ConfigurationDuffing.NumberOfAccessories       = 3;
	ConfigurationDuffing.DenseOutputNumberOfPoints = 1000;
	
	ProblemSolver ScanDuffing(ConfigurationDuffing, SelectedDevice);
	
	ScanDuffing.SolverOption(ThreadsPerBlock, BlockSize);
	ScanDuffing.SolverOption(InitialTimeStep, 1e-2);
	ScanDuffing.SolverOption(Solver, RKCK45);
	ScanDuffing.SolverOption(ActiveNumberOfThreads, NumberOfThreads);
	
	ScanDuffing.SolverOption(DenseOutputEnabled, 1);
	ScanDuffing.SolverOption(DenseOutputTimeStep, -1e-2);
	
	ScanDuffing.SolverOption(MaximumTimeStep, 1e3);
	ScanDuffing.SolverOption(MinimumTimeStep, 1e-14);
	ScanDuffing.SolverOption(TimeStepGrowLimit, 10.0);
	ScanDuffing.SolverOption(TimeStepShrinkLimit, 0.2);
	ScanDuffing.SolverOption(MaxStepInsideEvent, 50);
	ScanDuffing.SolverOption(MaximumNumberOfTimeSteps, 0);
	
	ScanDuffing.SolverOption(RelativeTolerance, 0, 1e-9);
	ScanDuffing.SolverOption(RelativeTolerance, 1, 1e-9);
	ScanDuffing.SolverOption(AbsoluteTolerance, 0, 1e-9);
	ScanDuffing.SolverOption(AbsoluteTolerance, 1, 1e-9);
	
	ScanDuffing.SolverOption(EventTolerance, 0, 1e-6);
	ScanDuffing.SolverOption(EventTolerance, 1, 1e-6);
	ScanDuffing.SolverOption(EventDirection,   0, -1);
	ScanDuffing.SolverOption(EventDirection,   1,  0);
	ScanDuffing.SolverOption(EventStopCounter, 0,  0);
	ScanDuffing.SolverOption(EventStopCounter, 1,  0);
	
// SIMULATIONS ------------------------------------------------------------------------------------
	
	int NumberOfSimulationLaunches = NumberOfProblems / NumberOfThreads + (NumberOfProblems % NumberOfThreads == 0 ? 0:1);
	
	ofstream DataFile;
	DataFile.open ( "Duffing.txt" );
	
	clock_t SimulationStart = clock();
	clock_t TransientStart;
	clock_t TransientEnd;
	
	for (int LaunchCounter=0; LaunchCounter<NumberOfSimulationLaunches; LaunchCounter++)
	{
		FillSolverObject(ScanDuffing, Parameters_k_Values, Parameters_B, InitialConditions_X1, InitialConditions_X2, LaunchCounter * NumberOfThreads, NumberOfThreads);
		ScanDuffing.SynchroniseFromHostToDevice(All);
		
		TransientStart = clock();
		for (int i=0; i<1024; i++)
		{
			ScanDuffing.Solve();
			ScanDuffing.InsertSynchronisationPoint();
			ScanDuffing.SynchroniseSolver();
		}
		TransientEnd = clock();
			cout << "Transient iteration: " << LaunchCounter << "  Simulation time: " << 1000.0*(TransientEnd-TransientStart) / CLOCKS_PER_SEC << "ms" << endl << endl;
		
		for (int i=0; i<32; i++)
		{
			ScanDuffing.Solve();
			ScanDuffing.SynchroniseFromDeviceToHost(All);
			ScanDuffing.InsertSynchronisationPoint();
			ScanDuffing.SynchroniseSolver();
			
			SaveData(ScanDuffing, DataFile, NumberOfThreads);
		}
	}
	
	clock_t SimulationEnd = clock();
		cout << "Total simulation time: " << 1000.0*(SimulationEnd-SimulationStart) / CLOCKS_PER_SEC << "ms" << endl << endl;
	
	DataFile.close();
	
	cout << "Test finished!" << endl;
}

// AUXILIARY FUNCTION -----------------------------------------------------------------------------

void Linspace(vector<double>& x, double B, double E, int N)
{
    double Increment;
	
	x[0]   = B;
	
	if ( N>1 )
	{
		x[N-1] = E;
		Increment = (E-B)/(N-1);
		
		for (int i=1; i<N-1; i++)
		{
			x[i] = B + i*Increment;
		}
	}
}

void FillSolverObject(ProblemSolver& Solver, const vector<double>& k_Values, double B, double X10, double X20, int FirstProblemNumber, int NumberOfThreads)
{
	int k_begin = FirstProblemNumber;
	int k_end   = FirstProblemNumber + NumberOfThreads;
	
	int ProblemNumber = 0;
	for (int k=k_begin; k<k_end; k++)
	{
		Solver.SetHost(ProblemNumber, TimeDomain,  0, 0 );
		Solver.SetHost(ProblemNumber, TimeDomain,  1, 2*PI );
		
		Solver.SetHost(ProblemNumber, ActualState, 0, X10 );
		Solver.SetHost(ProblemNumber, ActualState, 1, X20 );
		
		Solver.SetHost(ProblemNumber, ControlParameters, 0, k_Values[k] );
		
		Solver.SetHost(ProblemNumber, Accessories, 0, 0 );
		Solver.SetHost(ProblemNumber, Accessories, 1, 0 );
		Solver.SetHost(ProblemNumber, Accessories, 2, 0 );
		
		ProblemNumber++;
	}
	
	Solver.SetHost(SharedParameters, 0, B );
}

void SaveData(ProblemSolver& Solver, ofstream& DataFile, int NumberOfThreads)
{
	int Width = 18;
	DataFile.precision(10);
	DataFile.flags(ios::scientific);
	
	for (int tid=0; tid<NumberOfThreads; tid++)
	{
		DataFile.width(Width); DataFile << Solver.GetHost(tid, ControlParameters, 0) << ',';
		DataFile.width(Width); DataFile << Solver.GetHost(SharedParameters, 0) << ',';
		DataFile.width(Width); DataFile << Solver.GetHost(tid, ActualState, 0) << ',';
		DataFile.width(Width); DataFile << Solver.GetHost(tid, ActualState, 1) << ',';
		DataFile.width(Width); DataFile << Solver.GetHost(tid, Accessories, 0) << ',';
		DataFile.width(Width); DataFile << Solver.GetHost(tid, Accessories, 1) << ',';
		DataFile.width(Width); DataFile << Solver.GetHost(tid, Accessories, 2);
		DataFile << '\n';
	}
}