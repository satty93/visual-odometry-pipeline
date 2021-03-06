function p = makeProcessFrame(parameters)

p = @processFrame;

params_harris_detector_ = parameters.harris_detector;
K_ = parameters.K;

%%% Tune this threshold
triangulation_angle_threshold_ = parameters.triangulation_angle_threshold; %35
suppression_radius_ = parameters.suppression_radius;
reprojection_error_threshold_ = parameters.reprojection_error_threshold;

ransacLocalization = makeRansacLocalization(parameters.ransac_localization);
is_exercise_triangulation_ = true;

function [State_i1, Transform_i1, inlier_mask, validity_mask, new_3D, new_2D] = ...
    processFrame(Image_i1, Image_i0, State_i0, i1)

%PROCESSFRAME Summary of this function goes here
%   Detailed explanation goes here

    %% Step 1 & 2:
    % A) Run p3p+ransac to get transformation and new keypoints, both matched
    % and unmatched. Given the images and the correspondences 2D<->3D
    % correspondences and K.
    [R_C_W, t_C_W, valid_tracked_keypoints, valid_p_W_landmarks, validity_mask, inlier_mask] = ...
    ransacLocalization(Image_i1, Image_i0,  State_i0.keypoints_correspondences, ...
                                  State_i0.p_W_landmarks_correspondences);
    
    % B) Retrieve transformation of points from cam to world
    Transform_i1 = [R_C_W, t_C_W];
    Inversed_Transform_i1 = [R_C_W', -R_C_W'*t_C_W];
    isLocalized = numel(R_C_W)>0;
    
    keypoints_correspondences_i1 = valid_tracked_keypoints(:, inlier_mask > 0); % WARNING: should we round, ceil floor?
    p_W_landmarks_correspondences_i1 = valid_p_W_landmarks(:,inlier_mask > 0);
    
    % Detect new keypoints
    harrisDetector = makeHarrisDetector(params_harris_detector_);
    query_keypoints = harrisDetector (Image_i1);
    
    query_keypoints = removeDuplicates(query_keypoints, keypoints_correspondences_i1, suppression_radius_);
    
    %% Step 3: trying to triangulate new landmarks
    last_obs_cand_kp_i1_global_var = 0;
    final_keypoints_correspondences_i1 = keypoints_correspondences_i1;
    final_p_W_landmarks_correspondences_i1 = p_W_landmarks_correspondences_i1;
          
    new_3D = [];
    new_2D = [];
    
    %First time we start:
    if (isempty(State_i0.first_obs_candidate_keypoints))
        new_first_obs_cand_kp_i1 = zeros(2, 0); % keypoints 
        new_first_obs_cand_tf_i1 = zeros(12, 0); % transform
        new_last_obs_cand_kp_i1 = zeros(2, 0); % keypoints
        if(isLocalized)
            new_first_obs_cand_kp_i1 = query_keypoints; % Non_matched_query_keypoints
            % TODO find better way to deal with the transform of the first
            % observed candidates
            new_first_obs_cand_tf_i1 = repmat(reshape(Transform_i1,12,1),...
                1, size(new_first_obs_cand_kp_i1, 2)); % Store as 12xM transform
            new_last_obs_cand_kp_i1 = new_first_obs_cand_kp_i1; %First time we store them we also fill last_obs as first_obs for uniformity
        else
            fprintf('[INFO] Iteration %d: set of first_observed_candidate_keypoints is empty and we have not localized \n', i1);
        end
        
        % F) FINAL RESULT
        State_i1.first_obs_candidate_keypoints = new_first_obs_cand_kp_i1;
        State_i1.first_obs_candidate_transform = new_first_obs_cand_tf_i1;
        State_i1.last_obs_candidate_keypoints = new_last_obs_cand_kp_i1;
    else
        %Subsequent times:
        % A) Store input for this part:
        first_obs_cand_kp_i0 = State_i0.first_obs_candidate_keypoints; 
        first_obs_cand_tf_i0 = State_i0.first_obs_candidate_transform;

        last_obs_cand_kp_i0 = State_i0.last_obs_candidate_keypoints;

        % B) Try to match all last_obs_cand_kp_i0
        [tracked_last_obs_cand_kp_i1, cand_validity_mask] = KLT(last_obs_cand_kp_i0, Image_i1, Image_i0);
        

        % C) If successful match, update track with new last obs kp, if unsuccessful
        % discard track, aka delete last and first observed candidate kp together with transform.
        last_obs_cand_kp_i1 = tracked_last_obs_cand_kp_i1 (:, cand_validity_mask > 0);
        first_obs_cand_kp_i1 = first_obs_cand_kp_i0(:, cand_validity_mask > 0);
        first_obs_cand_tf_i1 = first_obs_cand_tf_i0(:, cand_validity_mask > 0);

        %If current pose is ok continue, if not do nothing.
        if (isLocalized)
            % D) For all the updated last_obs_cand_kp_i1 and corresponding
            % first kp and tf do:
            %%% I) Check which are suitable to triangulate:
            
            %random_generator = randi(2,1,size(last_obs_cand_kp_i1, 2));
            %is_triangulable = random_generator > 1;
            is_triangulable = checkTriangulability(last_obs_cand_kp_i1, Transform_i1, ...
                                                                      first_obs_cand_kp_i1, first_obs_cand_tf_i1);
            fprintf('Number of triangulable points: %d \n', nnz(is_triangulable));
            triangulable_last_kp = last_obs_cand_kp_i1(:, is_triangulable);
            triangulable_last_tf = Transform_i1;
            triangulable_first_kp = first_obs_cand_kp_i1(:, is_triangulable);
            triangulable_first_tf = first_obs_cand_tf_i1(:, is_triangulable);

            %%% II) Triangulate
            % TODO can we actually use matlab's triangulate function?
            % A way to optimize the following would be to vectorize over sets with common
            % triangulable_first_tf...
            % These will be the new 2D-3D correspondences
            num_triang_kps = size(triangulable_last_kp, 2);
            X_s = zeros(3, num_triang_kps);
            list_reprojection_errors = zeros(1, num_triang_kps);
            
            if (is_exercise_triangulation_)
                homo_keypoints_last_fliped = [flipud(triangulable_last_kp) ; ones(1, size(triangulable_last_kp,2))]; % TODO not sure if this zeros should instead 
                homo_keypoints_first_fliped = [flipud(triangulable_first_kp) ; ones(1, size(triangulable_first_kp,2))];
                for i = 1:num_triang_kps
                    newX_cam_frame = linearTriangulation(homo_keypoints_last_fliped(:, i),...
                        homo_keypoints_first_fliped(:, i),...
                        (K_*triangulable_last_tf),...
                        (K_*reshape(triangulable_first_tf(:,i), 3, 4)));
                     X_s(:, i) = newX_cam_frame(1:3,:);
                end
            else
                for i = 1:num_triang_kps
                    [newX_cam_frame, reprojectionError] = ...
                    triangulate(flipud(triangulable_last_kp(:, i))',...
                                      flipud(triangulable_first_kp(:, i))',...
                                      (K_*triangulable_last_tf)',...
                                      (K_*reshape(triangulable_first_tf(:,i), 3, 4))');
                    newX_cam_frame = newX_cam_frame';
                    X_s(:, i) = newX_cam_frame;
                    list_reprojection_errors(i) = reprojectionError;
                end
            end

            %%% III) Update state
            %%%% a) Store new 2D-3D correspondences which are valid
            valid_reprojection = list_reprojection_errors < reprojection_error_threshold_;
            X_cam_frame = Inversed_Transform_i1*[X_s; ones(1,size(X_s,2))];
            valid_depth = X_cam_frame(3,:)>0;
            valid_indices = valid_depth & valid_reprojection;
            fprintf('Number of valid triangulated points: %d \n', nnz(valid_indices));
            points_3D_world_frame = X_s(:, valid_indices);
            % IS THIS CORRECT?
            points_3D_W = points_3D_world_frame;
            points_2D = triangulable_last_kp(:, valid_indices);
            
            new_3D = points_3D_W;
            new_2D = points_2D;
            
            %%%% b) Append to already known 2D-3D correspondences
            final_keypoints_correspondences_i1 = [keypoints_correspondences_i1,  points_2D];
            final_p_W_landmarks_correspondences_i1 = [p_W_landmarks_correspondences_i1, points_3D_W];
            
            points_2D_global_var = points_2D; % Only for plotting later...
            
            %%%% b) Clear triangulated tracks, both correctly and incorrectly
            %%%% triangulated
            clear_last_obs_cand_kp_i1 = last_obs_cand_kp_i1(:, is_triangulable == 0);
            clear_first_obs_cand_kp_i1 = first_obs_cand_kp_i1(:, is_triangulable == 0);
            clear_first_obs_cand_tf_i1 = first_obs_cand_tf_i1(:, is_triangulable == 0);
                

            % E) For the non_matched_query_keypoints, append them as new candidates to current candidates.
            %%% I) Create values:
            %%%% Remove duplicates btw query_keypoints and tracked
            %%%% last_obs_cand_kp_i1 since they will represent the same 3D
            %%%% points
            new_first_obs_cand_kp_i1 = removeDuplicates(...
                query_keypoints, last_obs_cand_kp_i1, suppression_radius_);
            disp(['Num of new keypoints: ' num2str(size(new_first_obs_cand_kp_i1,2))]);
            new_first_obs_cand_kp_i1_global_var = new_first_obs_cand_kp_i1;
            new_first_obs_cand_tf_i1 = repmat(reshape(Transform_i1, 12, 1), 1, size(new_first_obs_cand_kp_i1, 2));
            new_last_obs_cand_kp_i1 = new_first_obs_cand_kp_i1; %First time we store them we also fill last_obs as first_obs for uniformity

            %%% II) Append Results
            last_obs_cand_kp_i1 = [clear_last_obs_cand_kp_i1, new_last_obs_cand_kp_i1];
            first_obs_cand_kp_i1 = [clear_first_obs_cand_kp_i1, new_first_obs_cand_kp_i1];
            first_obs_cand_tf_i1 = [clear_first_obs_cand_tf_i1, new_first_obs_cand_tf_i1];

            % F) FINAL RESULT
            last_obs_cand_kp_i1_global_var = last_obs_cand_kp_i1;
            State_i1.last_obs_candidate_keypoints = last_obs_cand_kp_i1;
            State_i1.first_obs_candidate_keypoints = first_obs_cand_kp_i1;
            State_i1.first_obs_candidate_transform = first_obs_cand_tf_i1;
        end
    end % end of if (isempty(State_i0.first_obs_candidate_keypoints))
    % F) FINAL RESULTS
    State_i1.keypoints_correspondences = final_keypoints_correspondences_i1;
    State_i1.p_W_landmarks_correspondences = final_p_W_landmarks_correspondences_i1;
end

function is_triangulable = checkTriangulability(last_kps, last_tf, first_kps, first_tfs)
%%% last_tf: transformation from World to Camera of the last kps
%%% first_tf: transformation from World to Camera of the first kps
    %%% Tune this threshold
    angle_threshold = triangulation_angle_threshold_;
    %1) Compute last bearing vector in the World frame
    bearing_vector_last_kps = computeBearing(last_kps, last_tf);
    %2) Compute first bearing vector in the World frame
    bearing_vector_first_kps = zeros(3, size(first_tfs, 2));
    for i = 1:size(first_kps,2)
        first_tf = reshape(first_tfs(:, i), 3, 4);
        bearing_vector_first_kps(:, i) = computeBearing(first_kps(:, i), first_tf);
    end
    %3) Check which current kps are triangulable
    angles = zeros(1, size(bearing_vector_last_kps,2));
    for i = 1:size(bearing_vector_last_kps,2)
        angles(i) = atan2d(norm(cross(bearing_vector_last_kps(:,i)', bearing_vector_first_kps(:,i)')), ...
            dot(bearing_vector_last_kps(:,i)', bearing_vector_first_kps(:,i)'));
    end
    is_triangulable = angles > angle_threshold;
end

function bearings_in_world_frame = computeBearing(kps, tfs)
    % Get bearings orientation in cam frame
    bearings = K_\[kps; ones(1, size(kps,2))];
    % Get rot matrix from cam points to world
    R_C_W = tfs(:, 1:3);
    % Get bearings orientation in world frame
    bearings_in_world_frame = R_C_W*bearings;
end

end
