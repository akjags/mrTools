% getGlmStatistics.m
%
%      usage: [d, contrastBetas, T, F, bootstrap] = getGlmStatistics(d, params, verbose, precision, computeEstimates, computeTtests)
%         by: Julien Besle
%       date: 18/01/10
%        $Id$
%    purpose: Fits a GLM model to timeseries at each voxel of a volume
%               and computes mass-univariate T and F statistics (parametric and bootstrap)
%               with optional correction for temporal noise correlation and bootstrap-based FWE adjustment
%
%             d needs to have a stimulus convolution matrix
%    
%             references for noise correlation correction
%             Generalized Least Squares:
%                - Wicker & Fonlupt (2003) NeuroImage, 18, p589
%                - Burock & Dale (2000) Human Brain Mapping, 11, p249
%             Pre-whitening and variance correction:
%                - Woolrich et al. (2001) NeuroImage, 14(6), p1370
%             Generalized F-tests
%                - Kruggel et al. (2002) Medical image Analysis, 6, p65
%             reference for bootstrap and FWE adjustment testing
%                - Westfall, P.H., and S.S. Young. Resampling-based multiple testing. Wiley-Interscience, 1993

function [d, r2, contrastBetas, T, F, bootstrap] = getGlmStatistics(d, params, verbose, precision, computeEstimates, computeTtests, computeBootstrap)

approximate_value = 0;
r2=[];
T = [];
F = [];
bootstrap=struct;
contrastBetas = [];
%optimalXLength = [60 80 100 120 140 160 180 200];
%optimalXLength = round(120000/nFrames);  %empirical value that optimizes the speed of bootstrapping, probably depends on available memory
optimalXLength = 120; %optimizes the bootsrap computing time
optimalXLength = 60;   %optimizes the OLS residual and MSS computing time


%--------------------------------------------------- DEFAULT VALUES ------------------------------------%
if ieNotDefined('verbose'),verbose = 1;end
if ieNotDefined('precision'),precision = mrGetPref('defaultPrecision');end
if ieNotDefined('computeTtests'),computeTtests = 1;end
if ieNotDefined('computeEstimates'),computeEstimates = 1;end

if ieNotDefined('params')
  params = struct;
end

%default parameters

% check that contrasts and fTests have the same number of columns as the
% design matrix
if ~isfield(params,'contrasts') || isempty(params.contrasts)
  params.contrasts = {};
else
  if size(d.scm,2)~=size(params.contrasts,2)*d.nHrfComponents
    mrErrorDlg( 'contrasts incompatible with number of EVs');
    return;
  end
end

if~isfield(params,'numberContrasts')
  params.numberContrasts = 0;
end
contrasts = cell(1,params.numberContrasts);
for iContrast = 1:params.numberContrasts %convert contrasts to the same format as restrictions
  contrasts{iContrast} = params.contrasts(iContrast,:);
end

if ~isfield(params,'tTestSide')
   params.tTestSide = 'Both';
end

if ~isfield(params,'fTestNames') || isempty(params.fTestNames)
   params.fTestNames = {};
end
  
if ~isfield(params,'restrictions') || isempty(params.restrictions)
   params.restrictions = {};
else
   if size(d.scm,2)~=size(params.restrictions{1},2)*d.nHrfComponents
      mrErrorDlg( 'F tests incompatible with number of EVs');
      return;
   end
end
restrictions = params.restrictions;

if ~isfield(d,'nHrfComponents')
  d.nHrfComponents = size(d.scm,2)/d.nhdr;
end
if ~isfield(params,'componentsToTest') || isempty(params.componentsToTest)
   params.componentsToTest = ones(1,d.nHrfComponents);
end

if ~isfield(params,'componentsCombination') || isempty(params.componentsCombination)
   params.componentsCombination = 'Add';
end
if strcmp(params.componentsCombination,'Or') && d.nHrfComponents==1
  params.componentsCombination = 'Add';  %make sure this is set to add if there is only one component to test
end

if ~isfield(params,'bootstrapStatistics')
  params.bootstrapStatistics=0;
end
if ieNotDefined('computeBootstrap') %this forces bootstrapping on or off
  computeBootstrap = params.bootstrapStatistics;
end
if ~computeBootstrap
  params.nBootstrap = 0;
else
  if ~isfield(params,'nBootstrap') 
    params.nBootstrap =10000;
  end
end
if ~isfield(params, 'bootstrapIntervals') || isempty(params.bootstrapIntervals)
  params.bootstrapIntervals = 0;
end
if ~isfield(params,'alphaConfidenceIntervals') || isempty(params.alphaConfidenceIntervals)
  params.alphaConfidenceIntervals = .05;
end
if ieNotDefined('params') || ~isfield(params,'covCorrection') || ~isfield(params,'correctionType') || strcmp(params.correctionType,'none')
   params.covCorrection = 0;
end
if params.covCorrection
   if  ~isfield(params,'correctionType') || isempty(params.correctionType)
      params.correctionType = 'preWhitening';
   end
   if  ~isfield(params,'covEstimation') || isempty(params.covEstimation)
      params.covEstimation = 'singleTukeyTapers';
   else
      params.covEstimation = params.covEstimation;
   end
   if  ~isfield(params,'covEstimationAreaSize') || isempty(params.covEstimationAreaSize)
      params.covEstimationAreaSize= 1;
   else
      params.covEstimationAreaSize = params.covEstimationAreaSize;
   end
   if  ~isfield(params,'covFactorization') || isempty(params.covFactorization)
      params.covFactorization= 'Cholesky';
   else
      params.covFactorization = params.covFactorization;
   end
else
   params.correctionType = 'none';
end

%do not do anything if nothing is asked
if isempty(restrictions) && isempty(contrasts) && ~computeEstimates && ~computeTtests
  return;
end


%--------------------------------------------------- INITIALIZATION ------------------------------------%
% precalculate the normal equation for Ordinary Least Squares
[invCovEVs,pinv_X]=computeNormalEquations(d.scm);

nFrames = size(d.volumes,2);

residualForming = eye(nFrames) - d.scm*pinv_X; %this matrix computes the residuals directly
d.rdf = nFrames-size(d.scm,2)-1; %degrees of freedom for the residual          %SHOULD BE nFrames-size(d.scm,2)

if params.covCorrection && params.covEstimationAreaSize>1 && isfield(d,'roiPositionInBox') 
  d.dim(1) = nnz(d.roiPositionInBox);
end

%initialize variables for covariance matrix estimation
if params.covCorrection 
  if params.covEstimationAreaSize>1
    sliceAverager3D = ones(1,params.covEstimationAreaSize,params.covEstimationAreaSize)/params.covEstimationAreaSize^2;
    if ~isfield(d,'roiPositionInBox') %this is in case we only compute for voxels in the loaded ROIs
      longMargin = ceil(params.covEstimationAreaSize/2); %we exclude voxels that are not surrounded by voxels with valid data
      shortMargin = floor(params.covEstimationAreaSize/2);
    end
  end
  switch params.covEstimation
    case 'singleTukeyTapers'
      tukeyM = 10;
      tukeyM = min(tukeyM,d.dim(4)-1);
      autoCorrelationParameters = NaN(tukeyM-1,d.dim(1),d.dim(2),d.dim(3),precision); %JB: this is to store the parameters of the ACF function (first 10 coeffs in this case)
  end
end

if strcmp(params.componentsCombination,'Or') %in this case, components of a given EV are tested independently from each other in an F-test
  params.componentsToTest = logical(diag(params.componentsToTest));
  %for contrasts, this amounts to  testing several contrats at once using an f test
  %So we have to change contrasts into f-tests (with the restriction that they have to be two-sided; this should be controlled for by the parameters)
  restrictions = [contrasts restrictions];
  params.parametricTests=1; %force computing parametric tests (because there are cases where we need to compute T-tests for bootstrap/randomizations
  contrasts = {};
end

%expand restriction matrices using kronecker products
for iR = 1:length(restrictions)
  restrictions{iR} = kron(restrictions{iR},params.componentsToTest);
end
for iContrast = 1:length(contrasts)
  contrasts{iContrast} = kron(contrasts{iContrast},params.componentsToTest);
end


if ~isempty(restrictions)
  
  %this has not been tested, but this is only for generalized F-tests which do not give the expected results anyway
  if strcmp(params.correctionType,'generalizedFTest')
    complementaryRestriction = cell(1,size(restrictions,1));
    baseRestriction =  kron(logical(eye(d.nhdr)),logical(params.componentsToTest)); 
    for iR = 1:length(restrictions)
      % not sure at all about these lines
      complementaryRestriction{iR} = baseRestriction - restrictions{iR};
      complementaryRestriction{iR} = complementaryRestriction{iR}(any(complementaryRestriction{iR},2),:);  
      % it actually doesn't make sense anymore now that F-tests can be made of any contrast
      % The logic relied on the fact that there were only elements on the diagonal of the restrictions matrix
      % There must be a generalization but I don't have time for this now
    end
    residualForming_f_tests = NaN(d.dim(4),d.dim(4),length(restrictions));
    residualForming_h = NaN(d.dim(4),d.dim(4),length(restrictions));
    traceRsV = NaN([d.dim(1:3) params.nBootstrap length(restrictions)]);
    effective_rdf = NaN(d.dim(1:3));
    effective_mdf = NaN([d.dim(1:3) params.nBootstrap length(restrictions)]);
    if ~approximate_value
      traceRV = NaN(d.dim(1:3));
    end
    scm_h = cell(1:length(restrictions));
    eig_residualForming_f_tests = cell(1:length(restrictions));
    for iR = 1:length(restrictions)
      scm_h{iR} = d.scm*complementaryRestriction{iR}';           
      residualForming_h(:,:,iR) = eye(nFrames) - scm_h{iR}*((scm_h{iR}'*scm_h{iR})^-1)*scm_h{iR}';       %TO REMOVE EVENTUALLY
      residualForming_f_tests(:,:,iR) = residualForming_h(:,:,iR) - residualForming; 
      [V,dump] = eig(residualForming_f_tests(:,:,iR));
      eig_residualForming_f_tests{iR} = V(:,1:size(restrictions{iR},1));
    end
  end
  
  mss = NaN(d.dim(1),d.dim(2),d.dim(3),params.nBootstrap,length(restrictions),precision);
  R_invCovEV_Rp = cell(1:length(restrictions));
  for iR = 1:length(restrictions)         %the degrees of freedom for the F-tests are the number of contrasts
    restrictions{iR} = restrictions{iR}(any(restrictions{iR},2),:); %remove lines of 0
    d.mdf(iR) = size(restrictions{iR},1); %this is provided that contrasts are independent and that they are no more than (regressors -1)
    %inv_R_invCovEV_Rp{iR} = (restrictions{iR}*invCovEVs*restrictions{iR}')^-1; 
    %I replaced all the precomputed inverses (previous line) by ml/mrDivide with the non-inverted matrix (faster and more accurate):
    R_invCovEV_Rp{iR} = restrictions{iR}*invCovEVs*restrictions{iR}';
  end
                         
end

% check roi
yvals = 1:d.dim(2);
slices = 1:d.dim(3);
  

%--------------------------------------------------- PRE-ALLOCATION ------------------------------------%

totalBytes = [];
if computeEstimates 
  if computeBootstrap && params.bootstrapIntervals
    [sortedBetas,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.dim(1),params.nBootstrap,precision);    %JB: replaces: d.ehdr = zeros(d.dim(1),d.dim(2),d.dim(3),d.nhdr,d.hdrlen);
    [ehdrBootstrapCIs,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.dim(1),d.dim(2),d.dim(3),precision);
  end
  [ehdr,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.dim(1),d.dim(2),d.dim(3),precision);    %JB: replaces: d.ehdr = zeros(d.dim(1),d.dim(2),d.dim(3),d.nhdr,d.hdrlen);
  [rss,totalBytes(end+1)] = alloc('NaN',d.dim(1),d.dim(2),d.dim(3),precision); %JB: this is to store the sum of square of the residual error term
  [tss,totalBytes(end+1)] = alloc('NaN',d.dim(1),d.dim(2),d.dim(3),precision); %JB: this is to store the total sum of square
  [s2,totalBytes(end+1)] = alloc('NaN',d.dim(1),d.dim(2),d.dim(3),precision); %JB: this is to store the estimated variance
end
if ~isempty(contrasts)
  [contrastBetas,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
  [thisContrastBetas,totalBytes(end+1)] = alloc('NaN',[d.dim(1) length(contrasts)],precision);
  if computeEstimates 
    if params.bootstrapIntervals
      [sortedContrasts,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) params.nBootstrap],precision);
      [contrastBootstrapCIs,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
    end
  end
  if computeTtests
    [thisContrastBetaSte,totalBytes(end+1)] = alloc('NaN',[d.dim(1) length(contrasts)],precision); 
    [T,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
    if computeBootstrap
      [bootstrap.Tp,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
      if ~strcmp(params.resampleFWEadjustment,'None')
        [bootstrap.maxTp,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
        if params.TFCE
          [bootstrap.tfceTp,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
          [bootstrap.maxTfceTp,totalBytes(end+1)] = alloc('NaN',[length(contrasts) d.dim(1) d.dim(2) d.dim(3)],precision);
        end
      end
    end
  end
end
if ~isempty(restrictions) 
  [mss,totalBytes(end+1)] = alloc('NaN',d.dim(1),1,precision);
  [thisF,totalBytes(end+1)] = alloc('NaN',d.dim(1),length(restrictions),precision);
  if params.parametricTests || params.randomizationTests
    [F,totalBytes(end+1)] = alloc('NaN',[length(restrictions) d.dim(1) d.dim(2) d.dim(3)],precision);
  end
  if computeBootstrap
    [bootstrap.Fp,totalBytes(end+1)] = alloc('NaN',[length(restrictions) d.dim(1) d.dim(2) d.dim(3)],precision);
    if ~strcmp(params.resampleFWEadjustment,'None')
      [bootstrap.maxFp,totalBytes(end+1)] = alloc('NaN',[length(restrictions) d.dim(1) d.dim(2) d.dim(3)],precision);
      if params.TFCE
        [bootstrap.tfceFp,totalBytes(end+1)] = alloc('NaN',[length(restrictions) d.dim(1) d.dim(2) d.dim(3)],precision);
        [bootstrap.maxTfceFp,totalBytes(end+1)] = alloc('NaN',[length(restrictions) d.dim(1) d.dim(2) d.dim(3)],precision);
      end
    end
  end
end
if params.covCorrection
  corrected_R_invCovEV_Rp = cell(1,length(restrictions));
  for iR = 1:length(restrictions)
    [corrected_R_invCovEV_Rp{iR},totalBytes(end+1)] = alloc('NaN',d.mdf(iR),d.mdf(iR),d.dim(1),'double');
  end
  switch(params.correctionType)
    case 'generalizedLeastSquares'
      %pre allocate temporary variables
      [corrected_pinv_X,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.dim(4),d.dim(1),'double'); %this array might become a bit large if a lot of values on the first dimension
      if computeEstimates || (~isempty(contrasts) && computeTtests)
        [invCorrectedCovEV,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.nhdr*d.nHrfComponents,d.dim(1),'double');
      end
    case 'varianceCorrection' %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
      [invCorrectedCovEV,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.nhdr*d.nHrfComponents,d.dim(1),'double');
      [correctedRdf,totalBytes(end+1)] = alloc('NaN',d.dim(1),1,'double');
    case 'preWhitening' %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
      [white_pinv_X,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.dim(4),d.dim(1),'double'); %this array might become a bit large if a lot of voxels on the first dimension
      [white_scm,totalBytes(end+1)] = alloc('NaN',d.dim(4),d.nhdr*d.nHrfComponents,d.dim(1),'double'); %this array might become a bit large if a lot of voxels on the first dimension
      [correctedRdf,totalBytes(end+1)] = alloc('NaN',d.dim(1),1,'double');
  end
end
[betas,totalBytes(end+1)] = alloc('NaN',d.nhdr*d.nHrfComponents,d.dim(1),precision);
[thisS2,totalBytes(end+1)] = alloc('NaN',d.dim(1),1,precision);
[thisResiduals,totalBytes(end+1)] = alloc('NaN',d.dim(4),d.dim(1),precision);

dInfo = whos('d');
totalBytes = sum(totalBytes)+dInfo.bytes;
if totalBytes> mrGetPref('maxBlocksize')
  if ~askuser(sprintf('(getGlmStatistics) This analysis requires %.2f Gb of data to be loaded in memory at once. Are you sure you want to proceed ?', sizeArray/1024^3));
    return;
  end
end

% turn off divide by zero warning
warning('off','MATLAB:divideByZero');



%--------------------------------------------------- MAIN LOOP: PARAMETER ESTIMATION ------------------------------------%
% display string
if verbose,hWaitBar = mrWaitBar(-inf,'(getGlmStatistics) Estimating model parameters');end
passesCounter = 0;
passesInBootstrap = d.dim(1);
switch(params.correctionType)
  case 'none'
    preBootstrapTime = 1;
  case 'generalizedLeastSquares'
    preBootstrapTime = 1.4;
  case 'varianceCorrection'
    preBootstrapTime = 550;
  case 'preWhitening'
    preBootstrapTime = 700;
end
totalPasses = prod(d.dim(1:3))*(params.nBootstrap+1+preBootstrapTime);

%these are the indices we will use to permute the residuals (with replacement)
if computeBootstrap %nBootstrap columns of randomly resampled indices 
  boostrapIndices = ceil(d.dim(4)*rand(params.nBootstrap,d.dim(4)));
end

% cycle through slices
for z = slices
  %permute timeseries frames in first dimension to compute residuals
  timeseries = permute(d.data(:,:,z,d.volumes),[4 1 2 3]); 
  % subtract off column means
  colmeans = repmat(mean(timeseries,1),[nFrames 1 1]);
  timeseries = timeseries - colmeans;
  % convert to percent signal change
  timeseries = 100*timeseries./colmeans;
  clear('colmeans');

  %--------------------------------------------------- MAIN LOOP: ORDINARY LEAST SQUARES ------------------------------------%
  % the following section has been optimized to run faster by
  % eliminating the x loops. in addition, the x dimension is divided in chunks of 60 points.
  % (which makes a difference only when system swaps ?)
  residuals = NaN(size(timeseries),precision);
%  residuals = NaN(d.dim(4),d.dim(1),d.dim(2),precision);
  for y = yvals
    % get OLS residuals
%     for iX = 1:ceil(d.dim(1)/optimalXLength)
%        xSubset = (iX-1)*optimalXLength+1 : min(iX*optimalXLength,d.dim(1));
%        residuals(:,xSubset,y) = residualForming*timeseries(:,xSubset,y); %JB resplaces residuals = timeseries-d.scm*d.ehdr(:,:,y,z);
%     end
    residuals(:,:,y) = residualForming*timeseries(:,:,y); %This is too long if X dim is large ?? (when calling with all data on the first dimension)
  end
  
  if params.covCorrection
    if params.covEstimationAreaSize>1     
      %average the residuals for covariance matrix estimation
      if isfield(d,'roiPositionInBox') %if the data are not spatially organized, we need to temporarily put them in a volume
        %first put them on a single line whose length is the product of the volume dimensions
        nVoxelsInBox = numel(d.roiPositionInBox);
        usedVoxelsInBox = reshape(d.roiPositionInBox|d.marginVoxels,nVoxelsInBox,1);
        averaged_residuals = NaN(d.dim(4),nVoxelsInBox,precision); 
        averaged_residuals(:,usedVoxelsInBox) = residuals;  
        %then reshape into a volume
        averaged_residuals = reshape(averaged_residuals,[d.dim(4) size(d.roiPositionInBox)]);
        %average
        averaged_residuals = convn(averaged_residuals,sliceAverager3D,'same');
        %put the data back in a new matrix with only the voxels of interest
        averaged_residuals = reshape(averaged_residuals,d.dim(4), nVoxelsInBox);
        averaged_residuals = averaged_residuals(:,d.roiPositionInBox);
        
        %reshape timeseries and residuals accordingly
        voxelsOfInterest = d.roiPositionInBox(usedVoxelsInBox);
        residuals = residuals(:,voxelsOfInterest);
        timeseries = timeseries(:,voxelsOfInterest);
        
        clear('usedVoxelsInBox');
      else
        averaged_residuals = NaN(size(residuals),precision);
        %averaged_residuals(isnan(residuals)) = 0;            %convert NaNs to 0... actually no, don't
        %average residuals over space
        averaged_residuals(:,longMargin:end-shortMargin,longMargin:end-shortMargin) = convn(residuals,sliceAverager3D,'valid');
      end
    else
      averaged_residuals = residuals;
    end
  end

  %---------------------- LOOP over Y: STATISTICS, NOISE COVARIANCE CORRECTION, RESIDUAL BOOTSTRAP ------------------------------------%
  for y = yvals  
 
    % Covariance matrix estimation 
    if params.covCorrection
      switch(params.covEstimation)
        %Single tapers
        case 'singleTukeyTapers'      %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
          this_s2 = var(averaged_residuals(:,:,y),1,1);   
          for tau=1:tukeyM-1   
            autoCorrelationParameters(tau,:,y,z) = .5*(1+cos(pi*tau/tukeyM)) * (sum(averaged_residuals(1:end-tau,:,y).*averaged_residuals(tau+1:end,:,y),1))./this_s2/(d.dim(4)-tau);
          end
        case 'nonParametricResiduals'
            %not implemented
        case 'nonParametricTimeSeries' %Can we do this on the timeseries instead of the residuals, like Wicker et al ?
            %not implemented
        case 'dampenedOscillator' %see Kruggel et al. (2002) Medical image Analysis, 6, p65
           %check if invertible/definite positive (might have negative values ?)
           this_s2 = var(averaged_residuals(:,:,y),1,1);  
           M = d.dim(4)-1;
           %M=30;
           for tau=1:M
              autoCorrelation(tau+1,:) = (sum(averaged_residuals(1:end-tau,:,y).*averaged_residuals(tau+1:end,:,y),1))./this_s2/(d.dim(4)-tau);
           end
           %initialParameters = [0 0 0];
           initialParameters = rand(1,3);
           options = optimset('Display','iter');
           for x = xvals
              [dampenedOscillatorParams(x,:), dummy, exitflag] = fminsearch(@(dummy) minimizeDampenedOscillator(dummy,(1:M)',autoCorrelation(1+(1:M),x)), initialParameters,options);
           end
           %not finished ...
       end
    end
    
    if ~strcmp(params.correctionType, 'generalizedFTest')
      %%%%%%%%%%%% COMPUTATIONS THAT CAN BE DONE BEFORE BOOTSTRAP (do not depend on the recomputed betas or residuals)
      if ismember(params.correctionType,{'none','varianceCorrection'})
          %estimate the OLS beta weights 
          betas = pinv_X*timeseries(:,:,y); 
      end

      if ~strcmp(params.correctionType, 'none')
        %find non-NaN voxels in this y line
        xvals = find(~any(isnan(timeseries(:,:,y))) & ~any(isnan(autoCorrelationParameters(:,:,y,z))));
        thisPassesCounter=passesCounter;
        for x = xvals
          if verbose,mrWaitBar( passesCounter/totalPasses, hWaitBar);end
          residualsAcm = makeAcm(autoCorrelationParameters(:,x,y,z),d.dim(4),params.covEstimation);
          
          switch(params.correctionType)
          
            case 'generalizedLeastSquares' %see Wicker & Fonlupt (2003) NeuroImage, 18, p589 and Burock & Dale (2000) Human Brain Mapping, 11, p249
              correctedCovEV = d.scm' / residualsAcm * d.scm;
              %corrected_pinv_X(:,:,x) = correctedCovEV \ d.scm';
              %betas(:,x) = corrected_pinv_X(:,:,x)  / residualsAcm * timeseries(:,x,y);
              corrected_pinv_X(:,:,x) = correctedCovEV \ d.scm' / residualsAcm;
              betas(:,x) = corrected_pinv_X(:,:,x)   * timeseries(:,x,y);
              %these are the new GLS residuals (but we don't need the OLS ones anymore, so just replace)
              residuals(:,x,y) = timeseries(:,x,y) - d.scm*betas(:,x);
              if computeEstimates || (~isempty(contrasts) && computeTtests) || ~isempty(restrictions)
                invCorrectedCovEV(:,:,x) = inv(correctedCovEV); 
              end

            case 'varianceCorrection' %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
              if computeEstimates || (~isempty(contrasts) && computeTtests) || ~isempty(restrictions)
                invCorrectedCovEV(:,:,x) = pinv_X * residualsAcm * pinv_X'; 
              end
              correctedRdf(x) = trace(residualForming * residualsAcm);

            case 'preWhitening' %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
              invResidualsAcm = inv(residualsAcm);
              % if this doesn't work, do pinv
              if sum(isnan(invResidualsAcm(:))) == length(invResidualsAcm(:))
                invResidualsAcm = pinv(residualsAcm);
                oneTimeWarning('pseudoInverseWarning','(getGlmStatistics) Residuals auto-correlation matrix is nearly singular, using pinv');
              end
              %compute inv(Cov)^1/2
              switch(params.covFactorization)
                case 'Cholesky'
                  try
                    preFilter = chol(invResidualsAcm);
                  catch exception
                    mrDisp(sprintf('(geGlmStatistics) Cannot factorize inverse noise covariance matrix because it is not positive definite (voxel %d %d %d)\n',x,y,z));
                    preFilter = [];
                  end
              end
              if ~isempty(preFilter)
                white_scm(:,:,x) = preFilter * d.scm;                 %%%% IS IT POSSIBLE TO SKIP THE FACTORIZATION BY ONLY USING (COV)^-1 LATER ON ??
                timeseries(:,x,y) = preFilter * timeseries(:,x,y);    %%%% NOT ACCORDING TO Kruggel et al. 2002...
                white_pinv_X(:,:,x) = (white_scm(:,:,x)'*white_scm(:,:,x))\white_scm(:,:,x)';
                white_residualForming = eye(nFrames) - white_scm(:,:,x)*white_pinv_X(:,:,x);
                betas(:,x) = white_pinv_X(:,:,x) * timeseries(:,x,y);
                if computeEstimates || computeTtests || ~isempty(restrictions) || params.nBootstrap>1
                  residuals(:,x,y) = white_residualForming * timeseries(:,x,y);
                end
                if computeEstimates || (~isempty(contrasts) && computeTtests) || ~isempty(restrictions)
                  correctedRdf(x) = trace(white_residualForming * preFilter * residualsAcm * preFilter');
                  invCorrectedCovEV(:,:,x) = inv(d.scm' * invResidualsAcm * d.scm); 
                end
              end
          end
            
          for iR = 1:length(restrictions)
            corrected_R_invCovEV_Rp{iR}(:,:,x) = restrictions{iR}*invCorrectedCovEV(:,:,x)*restrictions{iR}';
          end
          passesCounter = thisPassesCounter+x*preBootstrapTime;
        end
        passesCounter = thisPassesCounter+passesInBootstrap*preBootstrapTime;
      end
      
      %%%%%%%%%%%%%%%%% BOOTSTRAP LOOP %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
      for iBoot = 1:params.nBootstrap+1
        thisPassesCounter=passesCounter;
        if verbose,mrWaitBar( passesCounter/totalPasses, hWaitBar,'(getGlmStatistics) Estimating model parameters (bootstrap)');end
        if iBoot==1 && computeBootstrap
          countBootstrapT = zeros(d.dim(1), length(contrasts));
          countBootstrapF = zeros(d.dim(1), length(restrictions));
          if ~strcmp(params.resampleFWEadjustment,'None')
            countBootstrapMaxT =countBootstrapT;
            countBootstrapMaxF =countBootstrapF;
          end
        end

        if iBoot==1
          thisResiduals = residuals(:,:,y);
        else
          % the bootstrap time series is resampled from the residuals with replacement. 
          % it SHOULD NOT be recomputed as beta*scm+residuals, as this violates pivotality 
          %(see Westfall, P.H., and S.S. Young. Resampling-based multiple testing. Wiley-Interscience, 1993. p35-39, p79-80, p108)
          % Basically, pivotality means that the statistics should be centered around 0 under the null hypothesis
          % Adding the GLM to the bootstrapped time-series would make the bootstrapped statistics 
          % centered around their estimate from the actual time-series. 
          % resulting in low power because they will be very close to the actual statistic value
          % On the other hand, if the GLM is included in actual time-series, not in the bootstrapped
          %  - if the null hypothesis is true for this test, both the actual statistic
          %        and the bootrapped statistics distribution will be close to 0
          %  - but if the null hypothesis is not true for this test, the actual statistic will be far
          %        from the bootstrapped statistic distribution (which will still be around 0)
          %
          % here we replace the timeseries by the bootstrap timeseries for this y, 
          % as we won't need the actual timeseries anymore
          timeseries(:,:,y) = residuals(boostrapIndices(iBoot-1,:),:,y);
          switch(params.correctionType)
            case {'none','varianceCorrection'}
              %estimate the OLS beta weights 
              betas = pinv_X*timeseries(:,:,y); 
              %and we replace the residuals for this y by the bootstrap residuals
              thisResiduals = timeseries(:,:,y)-d.scm*betas;

            case 'generalizedLeastSquares' %see Wicker & Fonlupt (2003) NeuroImage, 18, p589 and Burock & Dale (2000) Human Brain Mapping, 11, p249
              for x = xvals
                if verbose,mrWaitBar( passesCounter/totalPasses, hWaitBar);end
                betas(:,x) = corrected_pinv_X(:,:,x) * timeseries(:,x,y);
                thisResiduals(:,x) = timeseries(:,x,y) - d.scm*betas(:,x);
                passesCounter = thisPassesCounter+x/2;
              end
              passesCounter = thisPassesCounter+passesInBootstrap/2;

            case 'preWhitening' %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
              for x = xvals
                if verbose,mrWaitBar( passesCounter/totalPasses, hWaitBar);end
                betas(:,x) = white_pinv_X(:,:,x) * timeseries(:,x,y);
                thisResiduals(:,x) = timeseries(:,x,y) -white_scm(:,:,x)*betas(:,x);
                passesCounter = thisPassesCounter+x/2;
              end
              passesCounter = thisPassesCounter+passesInBootstrap/2;
          end
        end

        if computeEstimates || ~isempty(restrictions)||~isempty(contrasts)
          switch(params.correctionType)
            case 'none'
              thisRss = sum(thisResiduals.^2,1)';
              thisS2 = thisRss/d.rdf;
            case 'generalizedLeastSquares' %see Wicker & Fonlupt (2003) NeuroImage, 18, p589 and Burock & Dale (2000) Human Brain Mapping, 11, p249
              thisPassesCounter=passesCounter;
              for x = xvals
                if verbose,mrWaitBar( passesCounter/totalPasses, hWaitBar);end
                residualsAcm = makeAcm(autoCorrelationParameters(:,x,y,z),d.dim(4),params.covEstimation);
                %this is the part that makes GLS much slower than PW when bootstrapping
                thisS2(x) = thisResiduals(:,x)' / residualsAcm * thisResiduals(:,x)/d.rdf;    %Wicker & Fonlupt (2003) 
                passesCounter = thisPassesCounter+x/2;
              end
              passesCounter = thisPassesCounter+passesInBootstrap/2;
            case {'varianceCorrection','preWhitening'} %see Woolrich et al. (2001) NeuroImage, 14(6), p1370
              thisRss = sum(thisResiduals.^2,1)';
              thisS2 = thisRss./correctedRdf;
          end
        end

        % T-tests
        if ~isempty(contrasts)
          for iContrast = 1:length(contrasts)
            if computeTtests
              switch(params.correctionType)
                case 'none'
                  thisContrastBetaSte(:,iContrast) = sqrt(thisS2.*(contrasts{iContrast}*invCovEVs*contrasts{iContrast}'));
                case {'generalizedLeastSquares','varianceCorrection','preWhitening'} 
                  for x = xvals
                    thisContrastBetaSte(x,iContrast) = sqrt(thisS2(x)*contrasts{iContrast} * invCorrectedCovEV(:,:,x) * contrasts{iContrast}');
                  end
              end
            end
            thisContrastBetas(:,iContrast) = (contrasts{iContrast}*betas)';
          end
          if computeTtests
            thisT = thisContrastBetas ./ thisContrastBetaSte;   
            thisT = permute(thisT,[1 2 3 5 4]); %put bootstrap dim at the end
            switch(params.tTestSide)
             case 'Both'
                thisT = abs(thisT);
             case 'Left'
                thisT = -1 *thisT;
            end
            if computeBootstrap
              if iBoot==1
                actualT = thisT;
                [indexSortActualT,indexReorderActualT,actualTisNotNaN] = initResampleFWE(actualT,params);
              else
                countBootstrapT = countBootstrapT+double(thisT>actualT); %T has already been transformed to be positive
                if ~strcmp(params.resampleFWEadjustment,'None')
                  %countBootstrapMaxT = countBootstrapMaxT + double(repmat(max(thisT,[],1),[d.dim(1) 1 1 1])>actualT);
                  countBootstrapMaxT = countBootstrapMaxT + resampleFWE(thisT,actualT,indexSortActualT,indexReorderActualT,actualTisNotNaN,params,d);
                end
              end
              if params.TFCE && ~strcmp(params.resampleFWEadjustment,'None') 
                %reshape to volume to apply TFCE and then reshape back to one dimension
                tempTfce = applyFslTFCE(reshapeToRoiBox(thisT,d.roiPositionInBox),'',0);
                tempTfce = permute(tempTfce,[4 1 2 3]);
                tempTfce = tempTfce(:,d.roiPositionInBox)';
                if iBoot == 1 %if it is the actual data
                  countBootstrapTfceT = zeros(size(thisT),precision);     %
                  countBootstrapMaxTfceT = zeros(size(thisT),precision);     %
                  actualBootstrapTfceT = tempTfce; 
                  [indexSortActualTfceT,indexReorderActualTfceT] = initResampleFWE(actualT,params,actualTisNotNaN);
                else
                  countBootstrapTfceT = countBootstrapTfceT + double(tempTfce>actualBootstrapTfceT);
                  %countBootstrapMaxTfceT = countBootstrapMaxTfceT + double(repmat(max(tempTfce,[],1),[d.dim(1) 1 1 1])>actualBootstrapTfceT);
                  if ~strcmp(params.resampleFWEadjustment,'None')
                    countBootstrapMaxTfceT = countBootstrapMaxTfceT + resampleFWE(tempTfce,actualBootstrapTfceT,indexSortActualTfceT,indexReorderActualTfceT,actualTisNotNaN,params,d);
                  end
                end
              end
            end
          end
        end

        %---------------------------------- F-TESTS --------------------------------------------------------%
        % basically, the F value (only for the EVs of interest) is 
        %     ((MSS)/ number of betas of interest) / (RSS/(number of samples - number of betas ?-1?))
        %     where MSS is the difference between the RSS without the EVs of interest and the RSS of the whole model
        % MSS has been computed as betas'*R'*(R*(X'*X)^-1*R')^-1 * R * betas, where R is a restrictions matrix that isolates the EVs of interest (such that R*X = Xinterest)
        % computed this way, the f-test can also be extended to contrasts and is equivalent to a two-sided T-test, if R describes a linear combination of EVs
        for iR = 1:length(restrictions)
          ss_beta = restrictions{iR}*betas;
          switch(params.correctionType)
            case 'none'
              %computing time seems to be the fastest on my machine when computing 60 values at a time
              %but this might be because it was swapping. anyway, I'll leave it this way because if it doesn't swap
              %it doesn't seem to make much difference
      %                optimalXLength = 10:200;                             %DEBUG/OPTIMIZATION
      %                computingTimes = zeros(size(optimalXLength));        %DEBUG/OPTIMIZATION
      %                for j = 1:length(optimalXLength)                     %DEBUG/OPTIMIZATION
      %                   tic
              for iX = 1:ceil(d.dim(1)/optimalXLength)
                xSubset = (iX-1)*optimalXLength+1 : min(iX*optimalXLength,d.dim(1));
                %mss(xSubset) = diag( ss_beta(:,xSubset)' * inv_R_invCovEV_Rp{iR} * ss_beta(:,xSubset) ); 
                mss(xSubset) = diag( ss_beta(:,xSubset)' / R_invCovEV_Rp{iR} * ss_beta(:,xSubset) );  
              end
      %                   computingTimes(j) = toc;                          %DEBUG/OPTIMIZATION
      %                end                                                  %DEBUG/OPTIMIZATION
      %                figure;plot(optimalXLength,computingTimes);          %DEBUG/OPTIMIZATION
              %mss = diag( ss_beta' * inv_R_invCovEV_Rp{iR} * ss_beta ); %%%%%this is too slow when Xdim is large
              %mss = diag( ss_beta' / R_invCovEV_Rp{iR} * ss_beta ); 

            case {'generalizedLeastSquares','varianceCorrection','preWhitening'} 
              for x = xvals
                 mss(x) = ss_beta(:,x)' / corrected_R_invCovEV_Rp{iR}(:,:,x) * ss_beta(:,x); 
              end
          end
          thisF(:,iR) = (mss/d.mdf(iR)) ./ thisS2;
        end
        if computeBootstrap && ~isempty(restrictions)
          if iBoot==1
            actualF = thisF;
            [indexSortActualF,indexReorderActualF,actualFisNotNaN] = initResampleFWE(actualF,params);
          else
            countBootstrapF = countBootstrapF+double(thisF>actualF);
            if ~strcmp(params.resampleFWEadjustment,'None')
              %countBootstrapMaxF = countBootstrapMaxF + double(repmat(max(thisF,[],1),[d.dim(1) 1 1 1])>actualF);
              countBootstrapMaxF = countBootstrapMaxF + resampleFWE(thisF,actualF,indexSortActualF,indexReorderActualF,actualFisNotNaN,params,d);
            end
          end
          if params.TFCE && ~strcmp(params.resampleFWEadjustment,'None') 
            %reshape to volume to apply TFCE and then reshape back to one dimension
            tempTfce = applyFslTFCE(reshapeToRoiBox(thisF,d.roiPositionInBox),'',0);
            tempTfce = permute(tempTfce,[4 1 2 3]);
            tempTfce = tempTfce(:,d.roiPositionInBox)';
            if iBoot == 1 %if it is the actual data
              countBootstrapTfceF = zeros(size(thisF),precision);     %
              countBootstrapMaxTfceF = zeros(size(thisF),precision);     %
              actualBootstrapTfceF = tempTfce; 
              [indexSortActualF,indexReorderActualF] = initResampleFWE(actualBootstrapTfceF,params,actualFisNotNaN);
            else
              countBootstrapTfceF = countBootstrapTfceF + double(tempTfce>actualBootstrapTfceF);
              if ~strcmp(params.resampleFWEadjustment,'None')
                %countBootstrapMaxTfceF = countBootstrapMaxTfceF + double(repmat(max(tempTfce,[],1),[d.dim(1) 1 1 1])>actualBootstrapTfceF);
                countBootstrapMaxTfceF = countBootstrapMaxTfceF + resampleFWE(tempTfce,actualBootstrapTfceF,indexSortActualTfceF,indexReorderActualTfceF,actualFisNotNaN,params,d);
              end
            end
          end
        end
        
        if iBoot==1  %Actual values to save
          if computeEstimates
            ehdr(:,:,y,z) = betas;
            switch(params.correctionType)
              case 'none'
                rss(:,y,z) = thisRss;     
              case {'generalizedLeastSquares','varianceCorrection','preWhitening'} 
                rss(:,y,z) = sum(thisResiduals.^2,1)'; %SHOULD RSS BE CORRECTED ?
            end
            tss(:,y,z) = sum(timeseries(:,:,y).^2,1)';     
            s2(:,y,z) = thisS2;
          end
          if ~isempty(contrasts)
            contrastBetas(:,:,y,z) = thisContrastBetas';
            if computeTtests
              T(:,:,y,z) = thisT';
            end
          end
          if ~isempty(restrictions) && (params.parametricTests || params.randomizationTests) 
            F(:,:,y,z) = thisF';
          end
        else
          if computeBootstrap && params.bootstrapIntervals && computeEstimates
            % we keep all the beta estimates if we need to compute bootstrap confidence intervals
            sortedBetas(:,:,iBoot-1) = betas;
            if ~isempty(contrasts)
              sortedContrasts(:,:,iBoot-1) = thisContrastBetas';
            end
          end
        end
        
        if ismember(params.correctionType,{'none','varianceCorrection','preWhitening'})
          passesCounter = thisPassesCounter+passesInBootstrap;
        end
      end
     
      %COMPUTE BOOTSTRAP STATISTICS
      if computeBootstrap && iBoot == params.nBootstrap+1 
        if ~isempty(contrasts) && computeTtests
          countBootstrapT(isnan(actualT))=NaN;
          bootstrap.Tp(:,:,y,z) = countBootstrapT'/params.nBootstrap;
          if ~strcmp(params.resampleFWEadjustment,'None')
            countBootstrapMaxT(isnan(actualT))=NaN;
            bootstrap.maxTp(:,:,y,z) = countBootstrapMaxT'/params.nBootstrap;
            if params.TFCE 
              countBootstrapTfceT(isnan(actualT))=NaN;
              bootstrap.tfceTp(:,:,y,z) = countBootstrapTfceT'/params.nBootstrap;
              countBootstrapMaxTfceT(isnan(actualT))=NaN;
              bootstrap.maxTfceTp(:,:,y,z) = countBootstrapMaxTfceT'/params.nBootstrap;
            end
          end
        end
        if ~isempty(restrictions)
          countBootstrapF(isnan(actualF))=NaN;
          bootstrap.Fp(:,:,y,z) = countBootstrapF'/params.nBootstrap;
          if ~strcmp(params.resampleFWEadjustment,'None')
            countBootstrapMaxF(isnan(actualF))=NaN;
            bootstrap.maxFp(:,:,y,z) = countBootstrapMaxF'/params.nBootstrap;
            if params.TFCE 
              countBootstrapTfceF(isnan(actualF))=NaN;
              bootstrap.tfceFp(:,:,y,z) = countBootstrapTfceF'/params.nBootstrap;
              countBootstrapMaxTfceF(isnan(actualF))=NaN;
              bootstrap.maxTfceFp(:,:,y,z) = countBootstrapMaxTfceF'/params.nBootstrap;
            end
          end
        end
        if params.bootstrapIntervals && computeEstimates
          lowerBoundIndex = max(1,floor(params.alphaConfidenceIntervals/2*params.nBootstrap));
          upperBoundIndex = min(params.nBootstrap,ceil((1-params.alphaConfidenceIntervals/2)*params.nBootstrap));
          sortedBetas = sort(sortedBetas,3);
          ehdrBootstrapCIs(:,:,y,z) = sortedBetas(:,:,upperBoundIndex)-sortedBetas(:,:,lowerBoundIndex);
          if ~isempty(contrasts)
            sortedContrasts = sort(sortedContrasts,3);
            contrastBootstrapCIs(:,:,y,z) = sortedContrasts(:,:,upperBoundIndex)-sortedContrasts(:,:,lowerBoundIndex);
          end
        end
      end
        
        
    else
      %Generalized F-tests - Not debugged
      %see Kruggel et al. (2002) Medical image Analysis, 6, p65
      %Does not give the expected result, but didn't have time to debug
      %anyway, less accurate and not obvious that it is much faster than other methods, so not worth the trouble
      ehdr(:,:,y,z) = pinv_X*timeseries(:,:,y);    % get OLS hdr
      if computeTtests || ~isempty(restrictions) || computeEstimates
        for x = xvals
          if verbose,mrWaitBar( (((y-min(yvals)) + d.dim(2)*(z-min(slices)))*d.dim(1)+x-min(xvals))/ prod(d.dim(1:3)), hWaitBar);end
          if ~any(isnan(timeseries(:,x,y))) && ~any(isnan(autoCorrelation(:,x)))
                       residualsAcm = makeAcm(autoCorrelationParameters(:,x,y,z),d.dim(4),params.covEstimation); 
            if approximate_value 
               effective_rdf(x,y,z) = d.dim(4)*(d.dim(4)-d.nhdr*d.nHrfComponents)/trace(residualsAcm*residualsAcm);
            else %this is the exact value (longer and not very different for large N, which is usually the case for fMRI data)
               RV = residualForming*residualsAcm;           
               traceRV(x,y,z) = trace(RV);       
               effective_rdf(x,y,z) = traceRV(x,y,z)^2/trace(RV*RV);  
            end

            for iR = 1:length(restrictions)
               if approximate_value
                  temp = eig_residualForming_f_tests{iR}'*residualsAcm*eig_residualForming_f_tests{iR};   %SEE IF FASTER WHEN LOOP INSTEAD OF TRACE
                  effective_mdf(x,y,z,1,iR) = trace(temp)^2 / trace(temp.^2);                                      %SEE IF FASTER WHEN LOOP INSTEAD OF TRACE
                  traceRsV(x,y,z,1,iR) = trace(residualForming_f_tests(:,:,iR)*residualsAcm);
               else
                  RsV = residualForming_f_tests(:,:,iR)*residualsAcm;  %%this is the exact value (longer)
                  traceRsV(x,y,z,1,iR) = trace(RsV);
                  effective_mdf(x,y,z,1,iR) = traceRsV(x,y,z,1,iR)^2/trace(RsV*RsV);    
               end
            end
          end
        end
      end
      %from Burock and Dale 2000 
      for iR = 1:length(restrictions)
        ss_beta = restrictions{iR}*ehdr(:,:,y,z,1);
        for iX = 1:ceil(d.dim(1)/optimalXLength)
          xSubset = (iX-1)*optimalXLength+1 : min(iX*optimalXLength,d.dim(1));
          %mss(xSubset,y,z,1,iR) = diag( ss_beta(:,xSubset)' * inv_R_invCovEV_Rp{iR} * ss_beta(:,xSubset) ); 
          mss(xSubset,y,z,1,iR) = diag( ss_beta(:,xSubset)' / R_invCovEV_Rp{iR} * ss_beta(:,xSubset) ); 
        end
      %mss(:,y,z,1,iR) = diag( ss_beta' * inv_R_invCovEV_Rp{iR} * ss_beta );%%%%%%%%%%%%%%%%%%%%%%%%%%THIS IS LIKELY TO BE SLOW WHEN X IS LARGE
      %mss(:,y,z,1,iR) = diag( ss_beta' / R_invCovEV_Rp{iR} * ss_beta ); 
      end
      if approximate_value
        F = repmat(effective_rdf.^2,[1 1 1 1 length(restrictions)]) .* traceRsV .* mss ./ effective_mdf.^2 ./ repmat(rss,[1 1 1 1 length(restrictions)]) / (d.rdf+1);
      else
        F = repmat(effective_rdf.^2,[1 1 1 1 length(restrictions)]) .* traceRsV .* mss ./ effective_mdf.^2 ./ repmat(rss,[1 1 1 1 length(restrictions)]) ./ repmat(traceRV,[1 1 1 1 length(restrictions)]);
      end
    end
  end
  clear('averaged_residuals','residuals');
  clear('timeseries');
end
% disp([num2str(optimalXLength) ' ' num2str(t) ';']);   %DEBUG

clear('residualForming');
oneTimeWarning('pseudoInverseWarning',0);

%Now in the case we computed contrasts on several components using option 'Or',
%we have to convert the appropriate F values into T values
if strcmp(params.componentsCombination,'Or') && ~isempty(params.contrasts)
  %T values are the square roots of the numberContrasts first F values 
  T = sqrt(F(1:params.numberContrasts,:,:,:));
  if params.parametricTests || params.randomizationTests
    %remove T values form F values array
    F = F(params.numberContrasts+1:end,:,:,:);
  end
  if computeBootstrap
    %bootstrap probabilities don't change
    bootstrap.Tp = bootstrap.Tp(1:params.numberContrasts,:,:,:);
    bootstrap.Fp = bootstrap.Fp(params.numberContrasts+1:end,:,:,:);
  end
  d.mdf=d.mdf(params.numberContrasts+1:end);
end

%reshape to the right dimensions
if ~isempty(params.contrasts)
  contrastBetas = permute(contrastBetas,[2 3 4 1]);
end
if computeEstimates
  % calculate variance accounted for by the estimated hdr
  r2 = 1 - rss./tss;     %JB: replaces: r2{y,z} = (1-sumOfSquaresResidual./sum(timeseries.^2));
  d.s2 = s2;
  %reshape nhdr and nhdrlen on two dimensions, put bootstrap dimension last, and swap nHrfComponents and nhdr order
  ehdr = permute(reshape(ehdr, d.nHrfComponents, d.nhdr, d.dim(1), d.dim(2), d.dim(3)),[3 4 5 2 1]);    
  d.ehdr = ehdr;
  if params.covCorrection
    d.autoCorrelationParameters = permute(autoCorrelationParameters,[2 3 4 1]);
  end
  if params.bootstrapIntervals && computeBootstrap
    ehdrBootstrapCIs = permute(reshape(ehdrBootstrapCIs, d.nHrfComponents, d.nhdr, d.dim(1), d.dim(2), d.dim(3)),[3 4 5 2 1]);
    d.ehdrBootstrapCIs = ehdrBootstrapCIs;
    if ~isempty(contrasts)
      contrastBootstrapCIs = permute(contrastBootstrapCIs,[2 3 4 1]);
      d.contrastBootstrapCIs = contrastBootstrapCIs;
    end
  end

end
if ~isempty(params.contrasts) && computeTtests
  T = permute(T,[2 3 4 1]);
  if computeBootstrap
    bootstrap.Tp = permute(bootstrap.Tp,[2 3 4 1]);
    if ~strcmp(params.resampleFWEadjustment,'None')
      bootstrap.maxTp = permute(bootstrap.maxTp,[2 3 4 1]);
      if params.TFCE 
        bootstrap.tfceTp = permute(bootstrap.tfceTp,[2 3 4 1]);
        bootstrap.maxTfceTp = permute(bootstrap.maxTfceTp,[2 3 4 1]);
      end
    end
  end
end
if ~isempty(restrictions) 
  if params.parametricTests || params.randomizationTests
    F = permute(F,[2 3 4 1]);
  end
  if computeBootstrap
    bootstrap.Fp = permute(bootstrap.Fp,[2 3 4 1]);
    if ~strcmp(params.resampleFWEadjustment,'None')
      bootstrap.maxFp = permute(bootstrap.maxFp,[2 3 4 1]);
      if params.TFCE 
        bootstrap.tfceFp = permute(bootstrap.tfceFp,[2 3 4 1]);
        bootstrap.maxTfceFp = permute(bootstrap.maxTfceFp,[2 3 4 1]);
      end
    end
  end
end

if verbose,mrCloseDlg(hWaitBar);end


function [array, arraySize] = alloc(defaultValues,varargin)

precision = varargin{end};
dimensions = cell2mat(varargin(1:end-1));
switch(lower(defaultValues))
  case 'nan'
    array = NaN(dimensions,precision);
  case 'ones'
    array = ones(dimensions,precision);
  case 'zeros'
    array = zeros(dimensions,precision);
end
arraySize = prod(dimensions);
switch(precision)
  case 'single'
    arraySize = arraySize*4;
  case 'double'
    arraySize = arraySize*8;
end

function outputData = reshapeToRoiBox(inputData,dataPosition)

%inputData must be size ([A B], where A equals the number of non-zero values in dataPosition
%outputData will be size ([size(dataPosition) B])
outputData = NaN([numel(dataPosition) size(inputData,2) size(inputData,3)]);
outputData(dataPosition>0,:,:) = inputData;
outputData = reshape(outputData,[size(dataPosition,1) size(dataPosition,2) size(dataPosition,3) size(outputData,2) size(outputData,3)]);


function [indexSort,indexReorder,isNotNaN] = initResampleFWE(actual,params,isNotNaN)

if strcmp(params.resampleFWEadjustment,'Step-down')
  %find the sorting index for actual non-nan T values (independently for each contrast)
  
  if ieNotDefined('isNotNaN')
    isNotNaN = ~any(isnan(actual),2); %if some voxels are nan only for some tests, they are excluded from this analysis. But that should not happen often, if ever
  end
  actual(~isNotNaN,:) = NaN;
  [sortedActual,indexSort] = sort(actual,1);
  indexSort = indexSort(~any(isnan(sortedActual),2),:); 
  [temp,indexReorder] = sort(indexSort,1);
else
  indexSort = [];
  indexReorder = [];
  isNotNaN = [];
end


%this function computes the sum of squared errors between the dampened oscillator
%model (for xdata) and the sample autocorrelation function (ydata)
function sse = minimizeDampenedOscillator(params, xdata,ydata)
  FittedCurve = params(1)^2 - exp(params(2) * xdata) .* cos(params(3)*xdata);
  ErrorVector = FittedCurve - ydata;
  sse = sum(ErrorVector.^2);
  
  
  