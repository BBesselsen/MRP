basefolder = '/Volumes/Bram stick/MRP';
nparticipants = 7;
speed = 1.25;
fs_force = 200;
close all;
calibration.gain = -6.284421236610132e+04;
calibration.offset = 4.047685881035096;

DAT = struct();

for PP = 1:nparticipants
    k5folder = fullfile(basefolder, sprintf('Subject%01d',PP), 'K5');
    FWBM_folder = fullfile(basefolder, sprintf('Subject%01d',PP), "FBWM");
    configFile = fullfile(basefolder,sprintf('Subject%01d',PP), 'Config_K5.xlsx');
    config = readtable(configFile, 'ReadVariableNames', true, 'VariableNamingRule','preserve');

    % Trim kolomnamen (vangt trailing spaces op)
    config.Properties.VariableNames = strtrim(config.Properties.VariableNames);

    DAT(PP).config = config;
    DAT(PP).participant_id = PP;

    nTrials = height(config);

    DAT(PP).VO2_L_min      = nan(nTrials,1);
    DAT(PP).VCO2_L_min     = nan(nTrials,1);
    DAT(PP).energy_kJ_min  = nan(nTrials,1);
    DAT(PP).pow_W          = nan(nTrials,1);
    DAT(PP).window_start_s = nan(nTrials,1);
    DAT(PP).window_end_s   = nan(nTrials,1);
    DAT(PP).mass           = nan(nTrials,1);
    DAT(PP).Pnet           = nan(nTrials,1);
    DAT(PP).CoT            = nan(nTrials,1);
    DAT(PP).force_m        = nan(nTrials,1);
    DAT(PP).force_exists   = false(nTrials,1);
    DAT(PP).force_file     = strings(nTrials,1);
    DAT(PP).force_window   = cell(nTrials,1);
    DAT(PP).VO2_raw        = cell(nTrials,1);
    DAT(PP).VCO2_raw       = cell(nTrials,1);
    DAT(PP).force_N        = cell(nTrials,1);
    DAT(PP).force_Nkg      = cell(nTrials,1);
    DAT(PP).idx_window     = cell(nTrials,1);

    % ---- K5 data processing ----
    DAT(PP).mass = config.mass(1,1);
    for i = 1:nTrials

        % Gebruik Trial_Number uit config (niet rij-index)
        k5_trial = config.Trial_Number(i);
        k5file = fullfile(k5folder, sprintf('Trial%d.xlsx', k5_trial));

        if isfile(k5file)

            opts = detectImportOptions(k5file, 'Sheet', 'Data', ...
                'VariableNamingRule', 'preserve');
            opts.VariableNamesRange = 'A1';
            opts.DataRange = 'A4';

            k5 = readtable(k5file, opts);
            t_raw = k5.("t");

            if isduration(t_raw)
                trial_time_sec = seconds(t_raw);
            elseif isdatetime(t_raw)
                trial_time_sec = seconds(timeofday(t_raw));
            else
                trial_time_sec = t_raw * 86400;
            end

            VO2_raw  = k5.("VO2");
            VCO2_raw = k5.("VCO2");

            DAT(PP).VO2_raw{i} = VO2_raw;
            DAT(PP).VCO2_raw{i} = VCO2_raw;

            if mean(VO2_raw, 'omitnan') > 100
                VO2_L_min = VO2_raw / 1000;
            else
                VO2_L_min = VO2_raw;
            end

            if mean(VCO2_raw, 'omitnan') > 100
                VCO2_L_min = VCO2_raw / 1000;
            else
                VCO2_L_min = VCO2_raw;
            end

            window = config.analysis_window_s(i);
            if isnan(window)
                warning('analysis_window_s is NaN for PP%d trial %d, skipping K5 window.', PP, i);
                continue
            end

            t_end = trial_time_sec(end);
            t_start = t_end - window;

            idx_k5 = trial_time_sec >= t_start & trial_time_sec <= t_end;
            DAT(PP).idx_window{i} = idx_k5;

            if ~any(idx_k5)
                warning('No valid K5 samples found for subject PP%d trial %d', PP, i);
            else
                DAT(PP).window_start_s(i) = trial_time_sec(find(idx_k5, 1, 'first'));
                DAT(PP).window_end_s(i)   = trial_time_sec(find(idx_k5, 1, 'last'));

                DAT(PP).VO2_L_min(i)  = mean(VO2_L_min(idx_k5), 'omitnan');
                DAT(PP).VCO2_L_min(i) = mean(VCO2_L_min(idx_k5), 'omitnan');

                DAT(PP).energy_kJ_min(i) = ...
                    16.58 * DAT(PP).VO2_L_min(i) + 4.51 * DAT(PP).VCO2_L_min(i);

                DAT(PP).pow_W(i) = DAT(PP).energy_kJ_min(i) * 1000 / 60;
            end

        else
            warning('K5 file not found: %s', k5file);
        end
    end

    % ---- Force processing ----
    for i = 1:nTrials
        n_force = DAT(PP).config.FWBM_File(i);

        if ~isnan(n_force)
            forcefolder = fullfile(FWBM_folder, sprintf('TN%06d.gai', n_force));

            if isfile(forcefolder)
                force_data = readtable(forcefolder,'FileType','text');
                DAT(PP).force_exists(i) = true;
                DAT(PP).force_file(i) = forcefolder;
            else
                warning('Forcefile not found: %s', forcefolder);
                DAT(PP).force_exists(i) = false;
                DAT(PP).force_file(i) = "";
            end
        else
            DAT(PP).force_exists(i) = false;
            DAT(PP).force_file(i) = "";
        end

        if DAT(PP).force_exists(i)
            window = config.analysis_window_s(i);
            if isnan(window), window = 180; end

            raw_force = table2array(force_data(:,3));
            force_data_N = calibration.gain * raw_force + calibration.offset;
            DAT(PP).force_N{i} = force_data_N;
            force_data_Nkg = force_data_N / DAT(PP).mass;
            DAT(PP).force_Nkg{i} = force_data_Nkg;

            n_samples = round(window * fs_force);
            if length(force_data_Nkg) < n_samples
                idx_force = 1:length(force_data_Nkg);
            else
                idx_force = (length(force_data_Nkg)-n_samples+1):length(force_data_Nkg);
            end
            DAT(PP).force_window{i} = force_data_Nkg(idx_force);
            DAT(PP).force_m(i) = mean(DAT(PP).force_window{i}, 'omitnan');
        end
    end

    % ---- Baseline selectie: dichtstbijzijnde voorgaande rust ----
    condtype = lower(string(DAT(PP).config.Condition_type));
    isBaseline = condtype == "baseline";
    baseline_idx = find(isBaseline);

    DAT(PP).base_per_trial = nan(nTrials, 1);
    for i = 1:nTrials
        preceding = baseline_idx(baseline_idx < i);
        if ~isempty(preceding)
            DAT(PP).base_per_trial(i) = DAT(PP).pow_W(preceding(end));
        else
            DAT(PP).base_per_trial(i) = DAT(PP).pow_W(baseline_idx(1));
        end
    end

    DAT(PP).base = DAT(PP).pow_W(baseline_idx(1));
    DAT(PP).Pnet = DAT(PP).pow_W - DAT(PP).base_per_trial;
    DAT(PP).CoT  = DAT(PP).Pnet / (DAT(PP).mass * speed);

    % ---- Forced trials: bepaal analyse-subset (fase 2 als >5 forced) ----
    isForced_all = ~isnan(DAT(PP).config.Force_level_pct);
    forced_idx_all = find(isForced_all);
    n_forced = sum(isForced_all);

    if n_forced > 5
        half = floor(n_forced / 2);
        fase2_idx = forced_idx_all(half+1:end);
        DAT(PP).isForce_analyse = false(nTrials, 1);
        DAT(PP).isForce_analyse(fase2_idx) = true;
        DAT(PP).has_two_phases = true;
    else
        DAT(PP).isForce_analyse = isForced_all;
        DAT(PP).has_two_phases = false;
    end

    % PP-specifieke exclusions (CV > 25%)
    if PP == 4
        DAT(PP).isForce_analyse = DAT(PP).isForce_analyse & ...
            (DAT(PP).config.Force_level_pct ~= 40 | isnan(DAT(PP).config.Force_level_pct));
    end

    % ---- Labels ----
    label = strings(nTrials, 1);
    for k = 1:nTrials
        if ~isnan(DAT(PP).config.Force_level_pct(k))
            label(k) = sprintf('%.0f%%', DAT(PP).config.Force_level_pct(k));
        else
            label(k) = DAT(PP).config.Condition_type{k};
        end
    end

    % ---- Optimal force (op analyse-subset) ----
    isForce_opt = DAT(PP).isForce_analyse;
    cot_opt     = DAT(PP).CoT(isForce_opt);
    force_opt   = DAT(PP).force_m(isForce_opt);
    if any(~isnan(cot_opt))
        [~, idx_opt]      = min(cot_opt);
        DAT(PP).opt_force = force_opt(idx_opt);
    else
        DAT(PP).opt_force = NaN;
    end
end

%% ===== FIGURES =====
close all;

% --- CoT vs force per PP ---
for PP = 1:nparticipants
    figure(PP); clf;
    hold on

    isForce = DAT(PP).isForce_analyse;

    x_force = DAT(PP).force_m(isForce);
    y_force = DAT(PP).CoT(isForce);

    [x_force_sorted, idx_sort] = sort(x_force);
    y_force_sorted = y_force(idx_sort);

    plot(x_force_sorted, y_force_sorted, 'o', 'LineWidth', 1.2)

    % Self-selected trials
    condtype = string(DAT(PP).config.Condition_type);
    isSelfSelected = contains(lower(condtype), 'self');
    x_self = DAT(PP).force_m(isSelfSelected);
    y_self = DAT(PP).CoT(isSelfSelected);

    plot(x_self, y_self, 'ro', 'MarkerSize', 8, 'LineWidth', 1.2)

    self_idx = find(isSelfSelected);
    for j = 1:numel(x_self)
        text(x_self(j), y_self(j), sprintf('  S%d', j), ...
            'Color', 'r', 'FontSize', 10);
    end

    % Minimum
    [y_min, idx_min] = min(y_force_sorted);
    x_min = x_force_sorted(idx_min);
    plot(x_min, y_min, 'rx', 'MarkerSize', 10, 'LineWidth', 1.5);

    xlabel('Mean force [N/kg]')
    ylabel('Cost of Transport [J kg^{-1} m^{-1}]')
    title(sprintf('Participant %01d: CoT vs force', PP))
    grid on

    legend('Forced trials', 'Self-selected', ...
        'Measured minimum', ...
        'Location', 'best')
    hold off
end

%% --- Force in self-selection phase ---

self_idx_all = cell(nparticipants, 1);
for PP = 1:nparticipants
    condtype = string(DAT(PP).config.Condition_type);
    self_idx_all{PP} = find(contains(lower(condtype), 'self'));
end

% Filter
cutoff_hz    = 0.01;
filter_order = 4;
[b, a] = butter(filter_order, cutoff_hz / (fs_force / 2), 'low');

colors = lines(nparticipants);

nrows_sub = ceil(nparticipants / 3);

for fase = 1:2
    figure();
    sgtitle(sprintf('Self-selection phase %d - raw and filtered force', fase));

    for PP = 1:nparticipants
        subplot(nrows_sub, 3, PP);
        hold on;

        idx_self = self_idx_all{PP};

        if length(idx_self) < fase
            title(sprintf('PP%d: no data', PP));
            continue
        end

        trial_nr = idx_self(fase);
        force_raw = DAT(PP).force_Nkg{trial_nr};

        if isempty(force_raw)
            title(sprintf('PP%d: no data', PP));
            continue
        end

        t = (0:length(force_raw)-1) / fs_force;
        force_filt = filtfilt(b, a, double(force_raw));

        plot(t, force_raw,  'Color', [0.7 0.7 0.7], 'LineWidth', 0.7 , 'DisplayName', 'Raw force [N/kg]');
        plot(t, force_filt, 'Color', colors(PP,:), 'LineWidth', 2, 'DisplayName','Filtered force [N/kg]');

        yline(DAT(PP).force_m(trial_nr), ':', ...
            'Color', colors(PP,:), 'LineWidth', 1.8, ...
            'DisplayName', sprintf('Mean force: %.2f N/kg', DAT(PP).force_m(trial_nr)));
        yline(DAT(PP).opt_force, '--k', 'LineWidth', 1.5, ...
            'DisplayName', sprintf('Opt. force (min CoT): %.2f N/kg', DAT(PP).opt_force));

        title(sprintf('Participant %d', PP));
        xlabel('Time [s]');
        ylabel('Force [N/kg]');
        legend(Location="north");
        ylim([-0.5 1.75]);
        grid on;
        hold off;
    end
end

%% --- Means pre en post in scatterplot ---

figure();
hold on;

force_s1_all = nan(nparticipants, 1);
force_s2_all = nan(nparticipants, 1);

for PP = 1:nparticipants
    idx_self = self_idx_all{PP};

    if length(idx_self) < 2
        continue
    end

    force_s1_all(PP) = DAT(PP).force_m(idx_self(1));
    force_s2_all(PP) = DAT(PP).force_m(idx_self(2));

    scatter(1, force_s1_all(PP), 80, colors(PP,:), 'filled', 'HandleVisibility', 'off');
    scatter(2, force_s2_all(PP), 80, colors(PP,:), 'filled', 'HandleVisibility', 'off');

    plot([1 2], [force_s1_all(PP) force_s2_all(PP)], '--', ...
        'Color', colors(PP,:), 'LineWidth', 1.2, ...
        'DisplayName', sprintf('PP%d', PP));
end

mean_s1 = mean(force_s1_all, 'omitnan');
mean_s2 = mean(force_s2_all, 'omitnan');

bar_width = 0.2;
bar(1, mean_s1, bar_width, 'FaceColor', [0.5 0.5 0.5], 'FaceAlpha', 0.3, ...
    'EdgeColor', 'k', 'LineWidth', 1.2, 'DisplayName', 'Group mean');
bar(2, mean_s2, bar_width, 'FaceColor', [0.5 0.5 0.5], 'FaceAlpha', 0.3, ...
    'EdgeColor', 'k', 'LineWidth', 1.2, 'HandleVisibility', 'off');

xlim([0.5 2.5]);
xticks([1 2]);
xticklabels({'Phase 1', 'Phase 2'});
ylabel('Mean force [N/kg]');
title('Self-selected force: phase 1 vs phase 2');
legend('Location', 'best');
grid on;
hold off;

%% --- Distance to minimum S1 and S2 ---

figure();
hold on;

colors = lines(nparticipants);

diff_s1 = nan(nparticipants, 1);
diff_s2 = nan(nparticipants, 1);

for PP = 1:nparticipants
    condtype = string(DAT(PP).config.Condition_type);

    isForce = DAT(PP).isForce_analyse;

    % Force at lowest CoT
    cot_force = DAT(PP).CoT(isForce);
    force_force = DAT(PP).force_m(isForce);
    [~, idx_min] = min(cot_force);
    min_force = force_force(idx_min);

    % Self-selected forces
    isSelf = contains(lower(condtype), 'self');
    idx_self = find(isSelf);
    if length(idx_self) < 2
        continue
    end

    s1_force = DAT(PP).force_m(idx_self(1));
    s2_force = DAT(PP).force_m(idx_self(2));

    diff_s1(PP) = s1_force - min_force;
    diff_s2(PP) = s2_force - min_force;

    scatter(1, diff_s1(PP), 80, colors(PP,:), 'filled', 'HandleVisibility', 'off');
    scatter(2, diff_s2(PP), 80, colors(PP,:), 'filled', 'HandleVisibility', 'off');
    plot([1 2], [diff_s1(PP) diff_s2(PP)], '--', ...
        'Color', colors(PP,:), 'LineWidth', 1.2, ...
        'DisplayName', sprintf('Participant %d', PP));
end

yline(0, '-k', 'LineWidth', 1.5, 'DisplayName', 'Energetic minimum', 'HandleVisibility', 'off');

mean_s1 = mean(diff_s1, 'omitnan');
mean_s2 = mean(diff_s2, 'omitnan');

plot([1 2], [mean_s1 mean_s2], '-k', 'LineWidth', 2.5, ...
    'DisplayName', 'Group mean');
scatter(1, mean_s1, 120, 'k', 'filled', 'HandleVisibility', 'off');
scatter(2, mean_s2, 120, 'k', 'filled', 'HandleVisibility', 'off');

ylim([-1 0.1]);
yticks(-1:0.2:0);
xlim([0.5 2.5]);
xticks([1 2]);
xticklabels({'Initial selection', 'Post-exploration'});
ylabel('\DeltaForce (F_{self-selected} - F_{minimum}) [N/kg]');
title('Deviation of self-selected force from energetic minimum');
legend('Location', 'best');
grid on;
hold off;

%% --- Steady-state quality check: CV ---

CV_threshold     = 25;
exclude_baseline = true;

fprintf('\n===== STEADY-STATE QUALITY CHECK =====\n');
fprintf('CV-drempel: %.0f%%\n\n', CV_threshold);

for PP = 1:nparticipants

    nTrials = height(DAT(PP).config);

    DAT(PP).QC_CV_VO2        = nan(nTrials, 1);
    DAT(PP).QC_CV_VCO2       = nan(nTrials, 1);
    DAT(PP).QC_flag          = false(nTrials, 1);
    DAT(PP).QC_skip_baseline = false(nTrials, 1);

    for i = 1:nTrials

        cond_type   = lower(string(DAT(PP).config.Condition_type{i}));
        is_baseline = contains(cond_type, 'baseline');

        if exclude_baseline && is_baseline
            DAT(PP).QC_skip_baseline(i) = true;
            continue
        end

        VO2_raw  = DAT(PP).VO2_raw{i};
        VCO2_raw = DAT(PP).VCO2_raw{i};

        if isempty(VO2_raw) || isempty(VCO2_raw)
            continue
        end

        if mean(VO2_raw, 'omitnan') > 100
            VO2_L  = VO2_raw  / 1000;
            VCO2_L = VCO2_raw / 1000;
        else
            VO2_L  = VO2_raw;
            VCO2_L = VCO2_raw;
        end

        % Analysis window
        window_s = DAT(PP).config.analysis_window_s(i);
        if isnan(window_s), continue; end

        if length(VO2_L) < window_s
            idx_w = 1:length(VO2_L);
        else
            idx_w = (length(VO2_L) - window_s + 1) : length(VO2_L);
        end

        VO2_win  = VO2_L(idx_w);
        VCO2_win = VCO2_L(idx_w);

        % CV
        cv_VO2  = (std(VO2_win,  'omitnan') / mean(VO2_win,  'omitnan')) * 100;
        cv_VCO2 = (std(VCO2_win, 'omitnan') / mean(VCO2_win, 'omitnan')) * 100;

        DAT(PP).QC_CV_VO2(i)  = cv_VO2;
        DAT(PP).QC_CV_VCO2(i) = cv_VCO2;

        if cv_VO2 > CV_threshold || cv_VCO2 > CV_threshold
            DAT(PP).QC_flag(i) = true;
            cond_str = DAT(PP).config.Condition_type{i};
            fprintf('FLAGGED: PP%d | Trial %2d | %-12s | CV_VO2: %.1f%% | CV_VCO2: %.1f%%\n', ...
                PP, i, cond_str, cv_VO2, cv_VCO2);
        end

    end
end

% Table
fprintf('\nPP   Trial Condition        CV_VO2(%%)   CV_VCO2(%%)  Status\n');
for PP = 1:nparticipants
    for i = 1:height(DAT(PP).config)

        if DAT(PP).QC_skip_baseline(i)
            continue
        end

        pct = DAT(PP).config.Force_level_pct(i);
        if ~isnan(pct)
            cond_str = sprintf('%.0f%%', pct);
        else
            cond_str = DAT(PP).config.Condition_type{i};
        end

        if DAT(PP).QC_flag(i)
            status = 'Flagged';
        else
            status = 'OK';
        end

        fprintf('%-4d %-6d %-15s %-12.1f %-12.1f %s\n', ...
            PP, i, cond_str, ...
            DAT(PP).QC_CV_VO2(i), ...
            DAT(PP).QC_CV_VCO2(i), ...
            status);
    end
end

%% --- Comfort vs force per subject ---
for PP = 1:nparticipants

    if ~isfield(DAT(PP), 'config') || ~istable(DAT(PP).config)
        fprintf('Subject %d: no valid config table.\n', PP);
        continue
    end

    if ~ismember('Comfort', DAT(PP).config.Properties.VariableNames)
        fprintf('Subject %d: "Comfort" not found.\n', PP);
        continue
    end

    if ~isfield(DAT(PP), 'force_m')
        fprintf('Subject %d: "force_m" not found.\n', PP);
        continue
    end

    comfort = DAT(PP).config.Comfort;
    force   = DAT(PP).force_m(:);

    n = min([length(comfort), length(force), height(DAT(PP).config)]);
    comfort = comfort(1:n);
    force   = force(1:n);

    isForced = DAT(PP).isForce_analyse(1:n);
    valid_forced = isForced & ~isnan(comfort) & ~isnan(force);

    valid_all = ~isnan(comfort) & ~isnan(force);

    if sum(valid_forced) < 3
        fprintf('Participant %d: force data not enough for fit.\n', PP);
        continue
    end

    figure(100 + PP); clf
    hold on;

    x_forced = force(valid_forced);
    y_forced = comfort(valid_forced);
    plot(x_forced, y_forced, 'ko', 'MarkerFaceColor', 'k', ...
        'DisplayName', 'Forced trials', 'MarkerSize', 5.3)

    condtype = string(DAT(PP).config.Condition_type);
    isSelfSelected = contains(lower(condtype), 'self');
    x_self = DAT(PP).force_m(isSelfSelected);
    y_self = comfort(isSelfSelected);

    plot(x_self, y_self, 'ro', 'MarkerSize', 8, 'LineWidth', 1.5, ...
        'DisplayName', 'Self-selected (S1, S2)')

    for j = 1:numel(x_self)
        if PP == 5 && j == 2
            text(x_self(j) - 0.01, y_self(j), sprintf('S%d', j), ...
                'Color', 'r', 'FontSize', 10, 'HorizontalAlignment', 'right');
        else
            text(x_self(j) + 0.01, y_self(j), sprintf('S%d', j), ...
                'Color', 'r', 'FontSize', 10, 'HorizontalAlignment', 'left');
        end
    end

    % Quadratic fit forced trials
    if numel(unique(x_forced)) >= 3
        p_forced = polyfit(x_forced, y_forced, 2);
        xfit = linspace(min(x_forced), max(x_forced), 200);
        yfit = polyval(p_forced, xfit);
        plot(xfit, yfit, '-', 'LineWidth', 1.2, ...
            'DisplayName', 'Quadratic fit (forced trials)')

        if p_forced(1) ~= 0
            x_ext = -p_forced(2) / (2 * p_forced(1));
            y_ext = polyval(p_forced, x_ext);
            if x_ext >= min(x_forced) && x_ext <= max(x_forced)
                plot(x_ext, y_ext, 'rx', 'MarkerSize', 10, 'LineWidth', 1.3, ...
                    'DisplayName', 'Top/bottom fit')
            end
        end
    else
        fprintf('Participant %d: too little unique force values for fit.\n', PP);
    end

    xlabel('Force [N/kg]')
    ylabel('Comfort score')
    title(sprintf('Participant %d - comfort scores', PP))
    grid on
    legend('Location', 'best')
    hold off
end

%% --- CoT vs force: PP1 and PP5 subplot ---
figure();
pp_select = [1 5];

for sp = 1:2
    PP = pp_select(sp);
    subplot(1, 2, sp);
    hold on;

    isForce = DAT(PP).isForce_analyse;

    x_force = DAT(PP).force_m(isForce);
    y_force = DAT(PP).CoT(isForce);

    [x_force_sorted, idx_sort] = sort(x_force);
    y_force_sorted = y_force(idx_sort);

    plot(x_force_sorted, y_force_sorted, 'o--', 'LineWidth', 1.2)

    condtype = string(DAT(PP).config.Condition_type);
    isSelfSelected = contains(lower(condtype), 'self');
    x_self = DAT(PP).force_m(isSelfSelected);
    y_self = DAT(PP).CoT(isSelfSelected);

    plot(x_self, y_self, 'ro', 'MarkerSize', 8, 'LineWidth', 1.2)

    for j = 1:numel(x_self)
        text(x_self(j), y_self(j), sprintf('  S%d', j), ...
            'Color', 'r', 'FontSize', 10);
    end

    [y_min, idx_min] = min(y_force_sorted);
    x_min = x_force_sorted(idx_min);
    plot(x_min, y_min, 'rx', 'MarkerSize', 10, 'LineWidth', 1.5);

    xlabel('Mean force [N/kg]')
    ylabel('Cost of Transport [J kg^{-1} m^{-1}]')
    title(sprintf('Subject %d', PP))
    grid on;
    hold off;
end

lgd = legend({'Forced trials', 'Self-selected', 'Measured minimum'}, ...
    'Location', 'best');


%% --- Comfort vs force: Participant 4 and 5 subplot ---
pp_select = [4 5];
set(groot, 'defaultLineLineWidth', 1.5)
set(groot, 'defaultAxesLineWidth', 1)
set(groot, 'defaultAxesFontSize', 12)

all_x = [];
all_y = [];
for PP = pp_select
    isForced = DAT(PP).isForce_analyse;
    comfort = DAT(PP).config.Comfort;
    force   = DAT(PP).force_m(:);
    n = min([length(comfort), length(force), height(DAT(PP).config)]);
    comfort = comfort(1:n);
    force   = force(1:n);
    isForced = isForced(1:n);
    valid_forced = isForced & ~isnan(comfort) & ~isnan(force);

    condtype = string(DAT(PP).config.Condition_type);
    isSelf = contains(lower(condtype), 'self');
    valid_self = isSelf & ~isnan(comfort) & ~isnan(force);

    all_x = [all_x; force(valid_forced); force(valid_self)];
    all_y = [all_y; comfort(valid_forced); comfort(valid_self)];
end
x_margin = 0.05 * (max(all_x) - min(all_x));
y_margin = 0.05 * (max(all_y) - min(all_y));
x_lim = [min(all_x) - x_margin, max(all_x) + x_margin];
y_lim = [min(all_y) - y_margin, max(all_y) + y_margin];

figure();
for sp = 1:2
    PP = pp_select(sp);
    subplot(1, 2, sp);
    hold on;

    comfort = DAT(PP).config.Comfort;
    force   = DAT(PP).force_m(:);
    n = min([length(comfort), length(force), height(DAT(PP).config)]);
    comfort = comfort(1:n);
    force   = force(1:n);

    isForced = DAT(PP).isForce_analyse(1:n);
    valid_forced = isForced & ~isnan(comfort) & ~isnan(force);

    x_forced = force(valid_forced);
    y_forced = comfort(valid_forced);

    plot(x_forced, y_forced, 'ko', 'MarkerFaceColor', 'k', ...
        'DisplayName', 'Forced trials', 'MarkerSize', 5.3)

    condtype = string(DAT(PP).config.Condition_type);
    isSelfSelected = contains(lower(condtype), 'self');
    x_self = DAT(PP).force_m(isSelfSelected);
    y_self = comfort(isSelfSelected);

    plot(x_self, y_self, 'ro', 'MarkerSize', 8, 'LineWidth', 1.5, ...
        'DisplayName', 'Self-selected (S1, S2)')

    xline(DAT(PP).opt_force, '--k', 'LineWidth', 1.5, ...
        'DisplayName', sprintf('Opt. force (min CoT): %.2f N/kg', DAT(PP).opt_force));
    offset_x = 0.01 * (x_lim(2) - x_lim(1));
    offset_y = 0.01 * (y_lim(2) - y_lim(1));
    for j = 1:numel(x_self)
        if PP == 5 && j == 2
            text(x_self(j) - offset_x, y_self(j) + offset_y, sprintf('S%d', j), ...
                'Color', 'r', 'FontSize', 10, 'HorizontalAlignment', 'right');
        else
            text(x_self(j) + offset_x, y_self(j) + offset_y, sprintf('S%d', j), ...
                'Color', 'r', 'FontSize', 10, 'HorizontalAlignment', 'left');
        end
    end

    if numel(unique(x_forced)) >= 3
        p_forced = polyfit(x_forced, y_forced, 2);
        xfit = linspace(min(x_forced), max(x_forced), 200);
        yfit = polyval(p_forced, xfit);
        plot(xfit, yfit, '-', 'LineWidth', 1.2, ...
            'DisplayName', 'Quadratic fit (forced trials)')

        if p_forced(1) ~= 0
            x_ext = -p_forced(2) / (2 * p_forced(1));
            y_ext = polyval(p_forced, x_ext);
            if x_ext >= min(x_forced) && x_ext <= max(x_forced)
                plot(x_ext, y_ext, 'rx', 'MarkerSize', 10, 'LineWidth', 1.3, ...
                    'DisplayName', 'Top/bottom fit')
            end
        end
    end

    xlabel('Force [N/kg]')
    ylabel('Comfort score')
    title(sprintf('Participant %d', PP))
    xlim(x_lim);
    ylim(y_lim);
    grid on;
    hold off;
end

subplot(1, 2, 2);
legend({'Forced trials', 'Self-selected (S1, S2)', 'Optimal force (min CoT)' ...
    'Quadratic fit (forced trials)', 'Top/bottom fit'}, ...
    'Location', 'best');

%% --- Wilcoxon signed-rank tests ---

valid = ~isnan(diff_s1) & ~isnan(diff_s2);
ds1 = diff_s1(valid);
ds2 = diff_s2(valid);

[p1, h1, stats1] = signrank(ds1);
[p2, h2, stats2] = signrank(ds2);
[p3, h3, stats3] = signrank(abs(ds1), abs(ds2));

fprintf('\n===== WILCOXON SIGNED-RANK TESTS =====\n');
fprintf('n = %d\n\n', sum(valid));

fprintf('1. DeltaF_S1 vs 0\n');
fprintf('   median = %.3f N/kg (IQR: %.3f to %.3f)\n', ...
    median(ds1), quantile(ds1, 0.25), quantile(ds1, 0.75));
fprintf('   p = %.3f, signed rank = %d\n\n', p1, stats1.signedrank);

fprintf('2. DeltaF_S2 vs 0\n');
fprintf('   median = %.3f N/kg (IQR: %.3f to %.3f)\n', ...
    median(ds2), quantile(ds2, 0.25), quantile(ds2, 0.75));
fprintf('   p = %.3f, signed rank = %d\n\n', p2, stats2.signedrank);

fprintf('3. |DeltaF_S1| vs |DeltaF_S2| (paired)\n');
fprintf('   median |S1| = %.3f, median |S2| = %.3f\n', ...
    median(abs(ds1)), median(abs(ds2)));
fprintf('   p = %.3f, signed rank = %d\n', p3, stats3.signedrank);

%% --- Maximum CoT reduction relative to baseline walking ---

fprintf('\n===== MAX CoT REDUCTION RELATIVE TO BASELINE WALKING =====\n');
fprintf('%-6s %-20s %-20s %-20s %-20s\n', ...
    'PP', 'Gross CoT baseline', 'Gross CoT optimal', 'Abs reduction', 'Pct reduction');

for PP = 1:nparticipants

    condtype   = lower(string(DAT(PP).config.Condition_type));
    isBaseWalk = condtype == "baseline-walk";
    pow_base_walk = DAT(PP).pow_W(isBaseWalk);

    if isempty(pow_base_walk) || all(isnan(pow_base_walk))
        fprintf('PP%-4d: geen baseline-walk trial gevonden\n', PP);
        continue
    end

    % Voor PP's met 2 baseline-walks: gebruik de eerste (pre-exploration)
    gross_CoT_base = pow_base_walk(1) / (DAT(PP).mass * speed);

    isForce_opt  = DAT(PP).isForce_analyse;
    cot_vals     = DAT(PP).CoT(isForce_opt);
    pow_vals     = DAT(PP).pow_W(isForce_opt);
    [~, idx_opt] = min(cot_vals);
    gross_CoT_opt = pow_vals(idx_opt) / (DAT(PP).mass * speed);

    abs_reduction = gross_CoT_base - gross_CoT_opt;
    pct_reduction = (abs_reduction / gross_CoT_base) * 100;

    fprintf('PP%-4d %-20.4f %-20.4f %-20.4f %-20.1f%%\n', ...
        PP, gross_CoT_base, gross_CoT_opt, abs_reduction, pct_reduction);
end

fprintf('\n');
