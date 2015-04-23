classdef Crazyflie
  properties
    manip;
    nominal_input;

    % crazyflieold
    % Q = diag([50 50 75 1 1 25 .001 .001 .001 2.0 2.0 5.0]);
    % R = eye(4);
    
    %Q = diag([100 100 200 2 2 100 1 1 1 1 1 5]);
    Q = diag([20 20 1000 1 1 500 .001 .001 .001 1 1 5]);
    R = eye(4);
    
    % crazyflieold
    % tvQ = diag([1 1 1 10 10 10 1 1 1 10 10 10]);
    % tvQf = diag([1 1 1 10 10 10 1 1 1 10 10 10]);
    % tvR = eye(4);
    
    % forest trajectory
    % tvQ = diag([70 70 70 10 10 200 .001 .001 .001 1.5 1.5 1]);
    % tvQf = diag([8 8 80 1 1 1 1 1 1 1 1 1]);
    
    % pipes trajectory
    % time 1.75
    % logs: 22, 41, 44, 47, 48, 49, 50
    % time 1.25
    % logs: 54
    % time 1.5
    % logs: 60, 68, 71, 72, 73
    tvQ = diag([150 150 100 .001 .001 500 .001 .001 .001 1.5 1.5 1]);
    tvQf = diag([150 150 50 .001 .001 1 .001 .001 .001 1 1 1]);
    
    % walls trajectory
    % tvQ = diag([60 100 60 .1 .1 500 .001 .001 .001 1.5 1.5 1]);
    % tvQf = diag([8 8 80 1 1 1 1 1 1 1 1 1]);
    
    tvR = eye(4);
  end
  
  methods
    
    function obj = Crazyflie()
      options.floating = true;
      obj.manip = RigidBodyManipulator('crazyflie.urdf',options);
      
      obj.nominal_input = .25*norm(getMass(obj.manip)*obj.manip.gravity)./ ...
          [obj.manip.force{1}.scale_factor_thrust obj.manip.force{2}.scale_factor_thrust ...
          obj.manip.force{3}.scale_factor_thrust obj.manip.force{4}.scale_factor_thrust]';
    end
    
    function run(obj, utraj, input_type, tspan, input_freq)
      if (nargin<3)
        input_type = '32bits';
      end
      input_frame = LCMCoordinateFrame('crazyflie_input',InputCoder(input_type),'u');
      utraj = setOutputFrame(utraj,input_frame);
      if (nargin<4)
        options.tspan = utraj.tspan;
        if (options.tspan(1)<0)
          options.tspan(1) = 0;
        end
      else
        options.tspan = tspan;
      end
      if (nargin<5)
        input_freq = 200;
      end
      options.input_sample_time = 1/input_freq;
      runLCM(utraj,[],options);
    end
    
    function runController(obj, controller)
      runLCM(controller,[]);
    end

    function controller = getPd(obj, xd, input_type)
      if (nargin<2)
        xd = zeros(12,1);
      end
      if (nargin<3)
        input_type = 'omegasqu';
      end
      
      if strcmp(input_type,'omegasqu')
        ROLL_KP = 1.2*.7;
        PITCH_KP = 1.2*.7;
        YAW_KP = 0;
        ROLL_RATE_KP = .8*.8;
        PITCH_RATE_KP = .8*.8;
        YAW_RATE_KP = .8*.6;
      elseif strcmp(input_type,'32bits')
        ROLL_KP = 1.2*3.5*180/pi;
        PITCH_KP = 1.2*3.5*180/pi;
        YAW_KP = 0.0;
        ROLL_RATE_KP = .8*70*180/pi;
        PITCH_RATE_KP = .8*70*180/pi; 
        YAW_RATE_KP = .8*50*180/pi;
      end
      
      u0 = zeros(4,1);

      K = [0 0 0 0 PITCH_KP YAW_KP 0 0 0 0 PITCH_RATE_KP YAW_RATE_KP;
           0 0 0 ROLL_KP 0 -YAW_KP 0 0 0 ROLL_RATE_KP 0 -YAW_RATE_KP;
           0 0 0 0 -PITCH_KP YAW_KP 0 0 0 0 -PITCH_RATE_KP YAW_RATE_KP;
           0 0 0 -ROLL_KP 0 -YAW_KP 0 0 0 -ROLL_RATE_KP 0 -YAW_RATE_KP];
             
      controller = LinearSystem([],[],[],[],[],K);
      
      state_estimator_frame = LCMCoordinateFrame('crazyflie_state_estimate',StateEstimatesCoder,'x');
      state_estimator_frame.addTransform(AffineTransform(state_estimator_frame,controller.getInputFrame,eye(length(xd)),-xd));
      controller = controller.inInputFrame(state_estimator_frame);
      
      input_frame = LCMCoordinateFrame('crazyflie_input',InputCoder(input_type),'u');
      controller.getOutputFrame.addTransform(AffineTransform(controller.getOutputFrame,input_frame,eye(length(u0)),u0));
      controller = controller.inOutputFrame(input_frame);      
    end
    
    function [controller,V] = getTilqr(obj, xd)
      if (nargin<2)
        xd = zeros(12,1);
      end
       
      options.angle_flag = [0 0 0 1 1 1 0 0 0 0 0 0]';
      [controller,V] = tilqr(obj.manip,xd,obj.nominal_input,obj.Q,obj.R,options);
            
      state_estimator_frame = LCMCoordinateFrame('crazyflie_state_estimate',StateEstimatesCoder,'x');
      state_estimator_frame.addTransform(AffineTransform(state_estimator_frame,controller.getInputFrame,eye(length(xd)),-xd));
      controller = controller.inInputFrame(state_estimator_frame);
      
      input_frame = LCMCoordinateFrame('crazyflie_input',InputCoder('omegasqu'),'u');
      controller.getOutputFrame.addTransform(AffineTransform(controller.getOutputFrame,input_frame,eye(length(obj.nominal_input)),obj.nominal_input-15));
      controller = controller.inOutputFrame(input_frame);      
    end
    
    function controller = getTvlqr(obj, xtraj, utraj, end_on_fixed_point)
      if (nargin<4)
        end_on_fixed_point = true;
      end
      
      if end_on_fixed_point
        xf = xtraj.eval(xtraj.tspan(2));
        [~,V] = obj.getTilqr(xf);
        Qf = V.S;
      else
        Qf = obj.tvQf;
      end
      
      xtraj = xtraj.setOutputFrame(obj.manip.getStateFrame);      
      utraj = utraj.setOutputFrame(obj.manip.getInputFrame);
      
      options.angle_flag = [0 0 0 1 1 1 0 0 0 0 0 0]';
      controller = tvlqr(obj.manip,xtraj,utraj,obj.tvQ,obj.tvR,Qf,options);
      
      state_estimator_frame = LCMCoordinateFrame('crazyflie_state_estimate',StateEstimatesCoder,'x');
      state_estimator_frame.addTransform(AffineTransform(state_estimator_frame,controller.getInputFrame,eye(12),-xtraj));
      controller = controller.inInputFrame(state_estimator_frame);
      
      input_frame = LCMCoordinateFrame('crazyflie_input',InputCoder('omegasqu'),'u');
      controller.getOutputFrame.addTransform(AffineTransform(controller.getOutputFrame,input_frame,eye(length(obj.nominal_input)),utraj-ConstantTrajectory(repmat(15,4,1))));
      controller = controller.inOutputFrame(input_frame);
    end
    
    function controller = getSOS(obj, xd)
      if (nargin<2)
        xd = zeros(12,1);
      end

      obj.manip = obj.manip.setInputLimits(-Inf*ones(4,1),Inf*ones(4,1));
      %options.angle_flag = [0 0 0 1 1 1 0 0 0 0 0 0]';
      [ctilqr,V] = tilqr(obj.manip,xd,obj.nominal_input,obj.Q,obj.R);

      % Do Taylor expansions
      x0 = Point(obj.manip.getStateFrame,xd);
      u0 = Point(obj.manip.getInputFrame,obj.nominal_input);
      sys = taylorApprox(obj.manip,0,x0,u0,3);

      % Options for control design
      options = struct();
      options.controller_deg = 1; % Degree of polynomial controller to search for
      options.max_iterations = 10; % Maximum number of iterations (3 steps per iteration)
      options.converged_tol = 1e-3; % Tolerance for checking convergence
      
      options.rho0 = 0.01; % Initial guess for rho

      options.clean_tol = 1e-6; % tolerance for cleaning small terms
      options.backoff_percent = 5; % 1 percent backing off

      options.degL1 = options.controller_deg + 1; % Chosen to do degree matching
      options.degLu = options.controller_deg - 1;
      options.degLu1 = 2;
      options.degLu2 = 2;
      options.degLup = 2;
      options.degLum = 2;

      % Perform controller design and verification
      disp('Starting verification...')
      [controller,V] = maxROAFeedback(sys,ctilqr,V,options);
      
      state_estimator_frame = LCMCoordinateFrame('crazyflie_state_estimate',StateEstimatesCoder,'x');
      state_estimator_frame.addTransform(AffineTransform(state_estimator_frame,controller.getInputFrame,eye(length(xd)),-xd));
      controller = controller.inInputFrame(state_estimator_frame);
      
      input_frame = LCMCoordinateFrame('crazyflie_input',InputCoder('omegasqu'),'u');
      controller.getOutputFrame.addTransform(AffineTransform(controller.getOutputFrame,input_frame,eye(length(obj.nominal_input)),obj.nominal_input-15));
      controller = controller.inOutputFrame(input_frame);      
    end
      
    function xtraj = simulateTilqr(obj)
      xd = [0 0 1 0 0 0 0 0 0 0 0 0]';
      options.angle_flag = [0 0 0 1 1 1 0 0 0 0 0 0]';
      controller = tilqr(obj.manip,xd,obj.nominal_input,obj.Q,obj.R,options);
      
      noise_max = [0.1 0.1 0.1 .5 .5 1 .1 .1 .1 .5 .5 .5]';
      noise = -noise_max+2*noise_max.*rand(12,1);
      
      sys = feedback(obj.manip,controller);
      xtraj = sys.simulate([0 5],xd+noise);
      
      v = obj.manip.constructVisualizer();
      v.playback(xtraj,struct('slider',true));
    end
    
    function xtraj = simulateTvlqr(obj, xtraj, utraj)
      options.angle_flag = [0 0 0 1 1 1 0 0 0 0 0 0]';
      controller = tvlqr(obj.manip,xtraj,utraj,obj.tvQ,obj.tvR,obj.tvQf,options);
            
      sys = feedback(obj.manip,controller);
      systraj = sys.simulate([0 5],xtraj.eval(0));
      
      v = obj.manip.constructVisualizer();
      v.playback(systraj,struct('slider',true));
    end
    
    function visualizeStateEstimates(obj)

      
      v = obj.manip.constructVisualizer();
      state_estimator_frame = LCMCoordinateFrame('crazyflie_state_estimate',StateEstimatesCoder,'x');
      state_estimator_frame.addTransform(AffineTransform(state_estimator_frame,v.getInputFrame,[eye(6),zeros(6)],zeros(6,1)));
      v = v.inInputFrame(state_estimator_frame);
      runLCM(v,[]);
      
      
      
    end

  end
  
end
