require "cohort_me/version"

module CohortMe

  def self.query(options={})
    start_from_interval = options[:start_from_interval] || 12
    interval_name = options[:period] || "weeks"
    first_day_of_week = options[:first_day_of_week] || :monday
    activation_class = options[:activation_class] 
    activation_table_name = options[:activation_table_name] || activation_class.table_name
    activation_user_id = options[:activation_user_id] || "user_id"
    activation_time_field = options[:activation_time_field] || "created_at"
    activation_conditions = options[:activation_conditions]

    activity_class = options[:activity_class] || activation_class
    activity_table_name = options[:activity_table_name] || activity_class.table_name
    activity_user_id = options[:activity_user_id] || "user_id"
    activity_time_field = options[:activity_time_field] || (activity_class == activation_class) ? activation_time_field : "created_at"
    activity_conditions = options[:activity_conditions] || activation_conditions
    activity_value = options[:activity_value]

    period_values = %w[weeks days months]
    raise "Period '#{interval_name}' not supported. Supported values are #{period_values.join(' or ')}" unless period_values.include? interval_name

    day_of_the_week_values = [:sunday, :monday, :tuesday, :wednesday, :thursday, :friday, :saturday]
    raise "Day of the week '#{first_day_of_week}' not supported. Supported values are #{day_of_the_week_values.join(' or ')}" unless day_of_the_week_values.include? first_day_of_week

    start_from = nil
    time_conversion = nil
    cohort_label = nil

    if interval_name == "weeks"
      start_from = start_from_interval.weeks.ago.at_beginning_of_week(start_day = first_day_of_week)
      time_conversion = 604800
    elsif interval_name == "days"
      start_from = start_from_interval.days.ago.beginning_of_day
      time_conversion = 86400
    elsif interval_name == "months"
      start_from = start_from_interval.months.ago.beginning_of_month
      time_conversion = 1.month.seconds
    end

    cohort_query = activation_class.select("#{activation_table_name}.#{activation_user_id}, MIN(#{activation_table_name}.#{activation_time_field}) as cohort_date").group("#{activation_user_id}").where("#{activation_time_field} > ?", start_from)

    if activation_conditions
      cohort_query = cohort_query.where(activation_conditions)
    end

    if %(mysql mysql2).include?(ActiveRecord::Base.connection.instance_values["config"][:adapter])
      select_sql = "#{activity_table_name}.#{activity_user_id} as user_id, #{activity_table_name}.#{activity_time_field}, cohort_date, CEIL(TIMEDIFF(#{activity_table_name}.#{activity_time_field}, cohort_date)/#{time_conversion}) as periods_out"
    elsif ActiveRecord::Base.connection.instance_values["config"][:adapter] == "postgresql"
      select_sql = "#{activity_table_name}.#{activity_user_id} as user_id, #{activity_table_name}.#{activity_time_field}, cohort_date, CEIL(extract(epoch from (#{activity_table_name}.#{activity_time_field} - cohort_date))/#{time_conversion}) as periods_out"
    else
      raise "database not supported"
    end

    if activity_value
      select_sql = "#{activity_table_name}.#{activity_value} as value, " + select_sql
    end

    data = activity_class.where("#{activity_time_field} > ?", start_from).select(select_sql).joins("JOIN (" + cohort_query.to_sql + ") AS cohorts ON #{activity_table_name}.#{activity_user_id} = cohorts.#{activation_user_id}")

    if activity_conditions
      data = data.where(activity_conditions)
    end

    return data
  end

  def self.analyze(options={})
    interval_name = options[:period] || "weeks"
    first_day_of_week = options[:first_day_of_week] || :monday

    data = self.query(options)

    analysis = {}
    data.each do |d|
      cohort = Time.parse(d.cohort_date.to_s).at_beginning_of_week(start_day = :sunday).to_date
      periods_out = d.periods_out.to_i

      analysis[cohort] = [] if analysis[cohort].nil?
      analysis[cohort][periods_out] = {} if analysis[cohort][periods_out].nil?

      if analysis[cohort][periods_out][d.user_id]
        analysis[cohort][periods_out][d.user_id][0] += 1
        analysis[cohort][periods_out][d.user_id][1] += (d[:value] || 0)
      else
        analysis[cohort][periods_out][d.user_id] = [1, (d[:value] || 0)]
      end
    end

    return analysis
  end

  def self.convert_to_cohort_date(datetime, interval, first_day_of_week)
    if interval == "weeks"
      return datetime.at_beginning_of_week(start_day = first_day_of_week).to_date
      
    elsif interval == "days"
      return Date.parse(datetime.strftime("%Y-%m-%d"))

    elsif interval == "months"
      return Date.parse(datetime.strftime("%Y-%m-1"))
    end
  end


end
